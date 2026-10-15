#if !os(WASI)
import Emo
import Foundation
import Testing
@testable import Usage

// The license server's end-to-end harness writes the plan and checks what the server stored.
private let planPath = ProcessInfo.processInfo.environment["DAL_LICENSE_E2E_PLAN"]

struct LicenseE2EPlan: Decodable {
    struct Load: Decodable {
        var device: String
        var platform: String
        var app: String
        var key: String?
        var model: String
        var modelVersion: String
    }

    struct RealModel: Decodable {
        var directory: String
    }

    var devices: String
    var now: String
    var retryScale: Int64
    var loads: [Load]
    var waitActivated: Bool
    var timeoutSeconds: Double
    var readyFile: String?
    var realModel: RealModel?
    var result: String
}

final class DeviceStorage: UsageStorage, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(_ path: String) { url = URL(fileURLWithPath: path) }

    func get(_ key: String) -> String? { lock.withLock { read()[key] } }

    func set(_ key: String, _ value: String) {
        lock.withLock {
            var values = read()
            values[key] = value
            guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return values
    }
}

final class RetryCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func add(_ device: String) { lock.withLock { counts[device, default: 0] += 1 } }
    var snapshot: [String: Int] { lock.withLock { counts } }
}

private func vectorPublicKeys() throws -> [String: String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("UsageTests/Resources/license_vectors.json")
    let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    var keys: [String: String] = [:]
    for key in vectors?["keys"] as? [[String: Any]] ?? [] {
        if let kid = key["kid"] as? String, let x963 = key["publicKeyX963"] as? String { keys[kid] = x963 }
    }
    return keys
}

@Suite(.enabled(if: planPath != nil, "set DAL_LICENSE_E2E_PLAN to run simulated devices against a local license server"))
struct LicenseE2ETests {
    @Test func devicesRunThePlan() async throws {
        let plan = try Foundation.JSONDecoder().decode(
            LicenseE2EPlan.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(planPath))))
        let publicKeys = try vectorPublicKeys()
        try #require(!publicKeys.isEmpty)
        let now = try #require(parseISO8601(plan.now))
        let scale = max(plan.retryScale, 1)
        let retries = RetryCounts()

        var clients: [String: LicenseClient] = [:]
        var storages: [String: DeviceStorage] = [:]
        for load in plan.loads {
            let device = load.device
            let storage = storages[device] ?? DeviceStorage(plan.devices + "/" + device + ".json")
            storages[device] = storage
            let identity = LicenseIdentity(appId: load.app, apiKey: load.key, platform: load.platform)
            let client = clients[device] ?? LicenseClient(
                storage: storage,
                now: { now },
                schedule: { delay, work in
                    retries.add(device)
                    scheduleLicenseRetry(after: delay / scale, work)
                },
                publicKeys: publicKeys,
                identity: { identity })
            clients[device] = client
            await client.modelLoaded(model: load.model, modelVersion: load.modelVersion)
        }
        if let readyFile = plan.readyFile {
            FileManager.default.createFile(atPath: readyFile, contents: Data())
        }

        func allActivated() -> Bool {
            plan.loads.allSatisfy { load in
                storages[load.device]?.loadLicense(load.key ?? load.app, load.model).activated == true
            }
        }
        if plan.waitActivated {
            let deadline = Date().addingTimeInterval(plan.timeoutSeconds)
            while !allActivated(), Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(allActivated(), "a device did not activate its license before the timeout")
        }

        var result: [String: Any] = ["retries": retries.snapshot]
        if let real = plan.realModel {
            let who = currentLicenseIdentity()
            let key = licenseStorageKey(who.namespace, EmoModel.id)
            UserDefaults.standard.removeObject(forKey: key)
            let suggestions = try await Emo(directory: real.directory).suggestions(for: "Pay my bills", limit: 3)
            await TelemetryDebug.shared.flushAndWait()
            #expect(!suggestions.isEmpty)
            result["realModel"] = [
                "installId": defaultStorage().persistentDeviceId(),
                "suggestions": suggestions.map(\.emoji),
                "stored": defaultStorage().get(key) ?? "",
            ]
            UserDefaults.standard.removeObject(forKey: key)
        }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: plan.result))
    }
}
#endif

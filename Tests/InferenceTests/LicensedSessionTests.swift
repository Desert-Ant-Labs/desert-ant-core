import Testing
@testable import Inference
@testable import Usage

private final class Recorder: InferenceSession, @unchecked Sendable {
    let runsConcurrently = true
    var devices: [String?] = []

    func inputWidth(_ name: String) -> Int? { name == "ids" ? 128 : nil }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        devices.append(deviceId)
        return []
    }
}

struct LicensedSessionTests {
    @Test func itForwardsTheRunAndWhatTheSessionReports() async throws {
        let base = Recorder()
        let session = LicensedSession(base: base, sdk: SDKInfo())

        _ = try await session.run(inputs: [:], outputs: [], deviceId: nil)

        #expect(base.devices == [nil])
        #expect(session.runsConcurrently)
        #expect(session.inputWidth("ids") == 128)
        #expect(session.inputWidth("mask") == nil)
    }

    @Test func aRunPassesOnTheDeviceIdBoundAroundIt() async throws {
        let base = Recorder()
        let session = LicensedSession(base: base, sdk: SDKInfo())

        try await InferenceContext.$deviceId.withValue("device-7") {
            _ = try await session.run(inputs: [:], outputs: [])
        }

        #expect(base.devices == ["device-7"])
    }

    // It queues a request on the shared client, so it runs only on a server platform where licensing points at a closed local port.
    @Test(.enabled(if: defaultPlatform == "server" && hostProvidedLicenseEndpoint()?.hasPrefix("http://127.0.0.1:") == true))
    func aRunWithADeviceIdStartsThatDevicesLicenseCheck() async throws {
        let device = "licensed-session-test-\(systemNowMs())"
        let sdk = SDKInfo(name: "desert-ant-core", version: "0", model: "not-a-model", modelVersion: "")
        let session = LicensedSession(base: Recorder(), sdk: sdk)

        _ = try await session.run(inputs: [:], outputs: [], deviceId: device)

        #expect(!DeviceLicenseClient.shared.holds.begin(deviceId: device, model: "not-a-model", at: systemNowMs()))
    }
}

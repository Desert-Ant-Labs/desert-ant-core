#if canImport(Darwin)
import Darwin
import Foundation

/// What this machine measured, remembered across launches.
///
/// The two things a model SDK cannot know ahead of time - how much work to hand
/// a device at once, and which device - are both "try it and keep the best", and
/// both need the answer to survive the process. This is that store: seconds per
/// item, keyed by the machine, the OS that schedules it, the model, and which
/// question is being asked.
///
/// Best rather than last: a run that happened while the machine was busy should
/// not condemn a choice forever.
public enum Measurements {
    private static let lock = NSLock()

    /// Every value tried for `axis`, with the best seconds per item each
    /// reached.
    public static func read(model: String, axis: String) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return (entries()[key(model: model)]?[axis] ?? [:]).filter {
            $0.value.isFinite && $0.value > 0
        }
    }

    /// Record what one run cost. Keeps the lowest seen.
    public static func record(model: String, axis: String, value: String,
                              secondsPerItem: Double) {
        guard secondsPerItem.isFinite, secondsPerItem > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var all = entries()
        var forMachine = all[key(model: model)] ?? [:]
        var forAxis = forMachine[axis] ?? [:]
        guard secondsPerItem < forAxis[value] ?? .greatestFiniteMagnitude else { return }
        forAxis[value] = secondsPerItem
        forMachine[axis] = forAxis
        all[key(model: model)] = forMachine
        write(all)
    }

    // MARK: - Storage

    private typealias Store = [String: [String: [String: Double]]]

    /// The machine, the OS that schedules it, and the model being measured.
    private static func key(model: String) -> String {
        var name = [CChar](repeating: 0, count: 256)
        var size = name.count
        #if os(macOS)
        sysctlbyname("hw.model", &name, &size, nil, 0)
        #else
        sysctlbyname("hw.machine", &name, &size, nil, 0)
        #endif
        return "\(String(cString: name))|"
            + "\(ProcessInfo.processInfo.operatingSystemVersionString)|\(model)"
    }

    private static func url() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let directory = base.appendingPathComponent("desert-ant", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("measurements.json")
    }

    private static func entries() -> Store {
        guard let url = url(), let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return [:] }
        return store
    }

    private static func write(_ store: Store) {
        guard let url = url(), let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

#else

/// Only Core ML measures anything today; elsewhere this remembers nothing.
public enum Measurements {
    public static func read(model: String, axis: String) -> [String: Double] { [:] }
    public static func record(model: String, axis: String, value: String,
                              secondsPerItem: Double) {}
}

#endif

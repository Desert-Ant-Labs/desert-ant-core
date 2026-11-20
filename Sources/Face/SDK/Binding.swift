import DesertAnt
#if os(Android)
// Do not import Foundation on Android: it pulls in the full ICU payload.
// Use FoundationEssentials to keep ICU out of the SDK.
import FoundationEssentials
#else
import Foundation
#endif
import JSON

/// How the bindings run Face, as the Kotlin and JavaScript SDKs see it: one model, and any number of
/// ``FaceLibrary`` values held here by handle, so every platform groups with this
/// one implementation.
///
/// Input payload: empty, or for `faces` the image as `u32 width`, `u32 height`,
/// `u32 channels` (3 or 4), then a length-prefixed blob of pixels.
///
/// Options payload: `string` operation, then `string` its arguments as JSON.
///
/// Result payload: `string` the answer as JSON.
///
/// Operations, with their arguments and answers:
/// - `faces`: `{minimumConfidence?, minimumSize?, maxFaces?}` -> `[DetectedFace]`, or `[FaceDetection]` from the
///   `detector` variant, which downloads and runs the detector alone. An option left out takes the Swift default
///   (`minimumConfidence` 0.35 for faceprints, 0.3 for the detector).
/// - `library.open`: `{library?}` (a saved library, or `{faces, names}` rows) -> `{handle}`.
/// - `library.close`, `library.save` (-> the library), `library.regroup`, `library.takeChanges` (-> `[FaceRecord]`),
///   `library.names`: `{handle}`.
/// - `library.add`: `{handle, faces: [DetectedFace], photo, date?}`; `library.addFace`: `{handle, face, id, photo, date?}`.
/// - `library.removePhoto`: `{handle, photo}`; `library.removeFace`: `{handle, id}`.
/// - `library.people`: `{handle, prominent?}` -> `[Person]`; `library.person`: `{handle, person}` -> `Person?`;
///   `library.personFor`: `{handle, faceprint}` -> `Person?`; `library.face`: `{handle, id}` -> `FaceRecord?`;
///   `library.suggestions`: `{handle, person, limit?}` -> `[String]`.
/// - `library.name`: `{handle, person, name?}`; `library.confirm`, `library.reject`: `{handle, id, person}`;
///   `library.newPerson`: `{handle, id, name}` -> `Int?`; `library.merge`: `{handle, other, person}`.
///
/// `date` is seconds since 1970. Mutating operations answer `null`.
public enum FaceBinding: ModelBinding {
    public static let id = FaceModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        FaceHost(.face(Face(directory: directory, cacheRoot: cacheRoot)))
    }

    public static func make(variant: String, cacheRoot: String?, directory: String?) -> (any BoundModel)? {
        variant == "detector" ? FaceHost(.detector(FaceDetector(directory: directory, cacheRoot: cacheRoot))) : nil
    }

    @_spi(FaceBindings)
    public static func make(detect: any InferenceSession, embed: any InferenceSession) -> any BoundModel {
        FaceHost(.face(Face(detect: detect, embed: embed)))
    }

    @_spi(FaceBindings)
    public static func make(detect: any InferenceSession) -> any BoundModel {
        FaceHost(.detector(FaceDetector(detect: detect)))
    }
}

final class FaceHost: BoundModel, @unchecked Sendable {
    enum Engine {
        case face(Face)
        case detector(FaceDetector)
    }

    let engine: Engine
    private let store = LibraryStore()

    init(_ engine: Engine) { self.engine = engine }

    func isDownloaded() -> Bool {
        switch engine {
        case .face(let face): face.isDownloaded()
        case .detector(let detector): detector.isDownloaded()
        }
    }

    func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        switch engine {
        case .face(let face): try await face.download(progress: progress)
        case .detector(let detector): try await detector.download(progress: progress)
        }
    }

    func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let op = options.string()
        let args = options.string()
        do {
            let answer: String
            if op == "faces" {
                let o = try JSONDecoder().decode(FacesArgs.self, from: args.isEmpty ? "{}" : args)
                let width = input.u32(), height = input.u32(), channels = input.u32()
                let image = try ImagePixels(width: width, height: height, channels: channels, bytes: input.blob())
                let defaults: FaceDetector.Options
                switch engine {
                case .face: defaults = .recognition
                case .detector: defaults = .init()
                }
                let options = FaceDetector.Options(
                    minimumConfidence: o.minimumConfidence ?? defaults.minimumConfidence,
                    minimumSize: o.minimumSize ?? defaults.minimumSize, maxFaces: o.maxFaces ?? defaults.maxFaces)
                switch engine {
                case .face(let face): answer = try JSONEncoder().encodeToString(try await face.faces(in: image, options: options))
                case .detector(let detector):
                    answer = try JSONEncoder().encodeToString(try await detector.faces(in: image, options: options))
                }
            } else {
                answer = try store.run(op, args)
            }
            var w = FFIWriter()
            w.string(answer)
            return w.bytes
        } catch {
            return nil
        }
    }
}

struct FacesArgs: Decodable {
    var minimumConfidence: Double?
    var minimumSize: Int?
    var maxFaces: Int?
}

final class LibraryStore: @unchecked Sendable {
    private let lock = NativeStateLock()
    private var libraries: [Int: FaceLibrary] = [:]
    private var next = 1

    final class Args: Decodable {
        var handle: Int?
        var library: FaceLibrary?
        var faces: [DetectedFace]?
        var face: DetectedFace?
        var faceprint: Faceprint?
        var photo: String?
        var date: Double?
        var id: String?
        var person: Int?
        var other: Int?
        var name: String?
        var prominent: Bool?
        var limit: Int?

        var day: Date? { date.map { Date(timeIntervalSince1970: $0) } }
    }

    struct Opened: Encodable { let handle: Int }

    func run(_ op: String, _ json: String) throws -> String {
        let a = try JSONDecoder().decode(Args.self, from: json.isEmpty ? "{}" : json)
        lock.lock()
        defer { lock.unlock() }
        if op == "library.open" { return try open(a) }
        guard let handle = a.handle, libraries[handle] != nil else { throw FaceError.invalidImage }
        if op == "library.close" {
            libraries[handle] = nil
            return "null"
        }
        guard let action = Self.actions[op] else { throw FaceError.invalidImage }
        return try action(&libraries[handle]!, a)
    }

    private func open(_ a: Args) throws -> String {
        let handle = next
        next += 1
        libraries[handle] = a.library ?? FaceLibrary()
        return try JSONEncoder().encodeToString(Opened(handle: handle))
    }

    typealias Action = @Sendable (inout FaceLibrary, Args) throws -> String

    static let actions: [String: Action] = [
        "library.save": { l, _ in try encode(l) },
        "library.names": { l, _ in try encode(Dictionary(uniqueKeysWithValues: l.names.map { (String($0.key), $0.value) })) },
        "library.regroup": { l, _ in l.regroup(); return "null" },
        "library.takeChanges": { l, _ in try encode(l.takeChanges()) },
        "library.add": { l, a in l.add(a.faces ?? [], photo: try need(a.photo), date: a.day); return "null" },
        "library.addFace": { l, a in l.add(try need(a.face), id: try need(a.id), photo: try need(a.photo), date: a.day); return "null" },
        "library.removePhoto": { l, a in l.remove(photo: try need(a.photo)); return "null" },
        "library.removeFace": { l, a in l.remove(face: try need(a.id)); return "null" },
        "library.people": { l, a in try encode(l.people(a.prominent == true ? .prominent : .all)) },
        "library.person": { l, a in try encode(l.person(try need(a.person))) },
        "library.personFor": { l, a in try encode(l.person(for: try need(a.faceprint))) },
        "library.face": { l, a in try encode(l.face(try need(a.id))) },
        "library.suggestions": { l, a in try encode(l.suggestions(for: try need(a.person), limit: a.limit ?? 20)) },
        "library.name": { l, a in l.name(try need(a.person), a.name); return "null" },
        "library.confirm": { l, a in l.confirm(try need(a.id), is: try need(a.person)); return "null" },
        "library.reject": { l, a in l.reject(try need(a.id), from: try need(a.person)); return "null" },
        "library.newPerson": { l, a in try encode(l.newPerson(from: try need(a.id), named: try need(a.name))) },
        "library.merge": { l, a in l.merge(try need(a.other), into: try need(a.person)); return "null" },
    ]

    private static func encode(_ value: some Encodable) throws -> String { try JSONEncoder().encodeToString(value) }

    private static func need<T>(_ value: T?) throws -> T {
        guard let value else { throw FaceError.invalidImage }
        return value
    }
}

#if os(Android)
import Android
// Foundation's locks would pull its internationalization library into the AAR.
private final class NativeStateLock {
    private var mutex = pthread_mutex_t()
    init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }
    func lock() { pthread_mutex_lock(&mutex) }
    func unlock() { pthread_mutex_unlock(&mutex) }
}
#else
private typealias NativeStateLock = NSLock
#endif

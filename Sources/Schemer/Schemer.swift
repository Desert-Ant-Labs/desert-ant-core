// The public Swift API. The pipeline is `Model.swift`; this is the lazy
// facade over it, and it is what every other language's binding drives.

import DesertAnt
import Foundation

public enum SchemerError: Error, CustomStringConvertible, Sendable {
    case invalidBundle(String)
    case invalidSchema(String)

    public var description: String {
        switch self {
        case .invalidBundle(let m): return "invalid model bundle: \(m)"
        case .invalidSchema(let m): return "invalid schema: \(m)"
        }
    }
}

/// On-device structured extraction: give it text and a schema, get back JSON
/// that matches the schema.
///
/// ```swift
/// let schemer = Schemer()
/// let schema: Schema = [
///     .string("merchant", describe: "the shop or vendor"),
///     .number("amount", describe: "total paid"),
///     .boolean("reimbursable"),
/// ]
/// let out = try await schemer.extract(from: receipt, schema: schema)
/// print(out.json)
/// ```
///
/// Nothing is generated. Every field is decoded by a head built for its type,
/// so the output is typed by construction: strings are always substrings of
/// the input, labels are always one of the values you declared, and a field
/// the text does not state comes back `null` rather than invented.
///
/// Runs wherever the core does: Core ML on Apple, LiteRT on
/// Android/Linux/Windows, the JS host on wasm. This type names none of them.
public final class Schemer: @unchecked Sendable {

    /// The compiled label graph takes a fixed candidate count.
    public static let maxLabelValues = Shapes.labelValues

    private let model: LoadedModel<Model>

    /// Creates an extractor. Nothing loads yet: the model loads on the first
    /// ``extract(from:schema:now:)`` or ``download(progress:)``, off your
    /// calling thread.
    ///
    /// `directory` is where the model lives. If it already contains the model
    /// (you pre-downloaded or shipped it there) it is used offline; otherwise
    /// the model is downloaded into it and reused offline afterward. With no
    /// `directory`, a managed cache location is used.
    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    /// Binding entry point that also supplies the platform base cache root
    /// under which the managed layout lives (the app cache dir on Android,
    /// node `~/.cache` on the web). On Apple/Linux FileManager provides it,
    /// so the public `init(directory:)` passes `nil`.
    @_spi(SchemerBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(SchemerModel.self, directory: directory, cacheRoot: cacheRoot) {
            files in try Model(assets: await .schemer(files: files))
        }
    }

    /// Creates an extractor from explicitly provided assets (the wasm
    /// self-hosted and custom-deployment paths).
    @_spi(SchemerBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { try Model(assets: assets) }
    }

    /// Switch named harness rules off (`Levers.swift`), so an evaluation can
    /// measure each one. Not for apps: every rule is on by default because
    /// each was measured to help.
    @_spi(SchemerEval)
    public static func disableHarnessRules(_ names: Set<String>) { Levers.disabled = names }

    /// Whether the model is available with no network.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load ahead of time, so the first extraction is instant.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Compile the model for this device ahead of time.
    ///
    /// The first use of each graph on the Neural Engine compiles it for the
    /// device. That cost is paid once per app install and it is large:
    /// measured on an M1, about 33 seconds before the first short record and
    /// 92 seconds before the first long document. Call this right after
    /// ``download(progress:)``, for example during onboarding, so the user's
    /// first extraction is fast. It downloads first if needed, and is a cheap
    /// no-op once warm.
    public func prewarm(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        let model = try await model.value()
        // Compiling touches every graph once; that is one call, not one per graph.
        try await InferenceContext.withCallGroup { try await model.prewarm(progress: progress) }
    }

    /// Await model readiness. The bindings use this to surface load errors
    /// eagerly; apps can just call ``extract(from:schema:now:)``.
    @_spi(SchemerBindings)
    public func waitUntilLoaded() async throws { _ = try await model.value() }

    /// Extract every field in `schema` from `text`.
    ///
    /// - Parameter now: the date relative expressions resolve against, read
    ///   as a day in the device's time zone. Defaults to today; pass a fixed
    ///   date to make results reproducible. The model never learns date
    ///   arithmetic - the runtime hands it `today=YYYY-MM-DD` and the
    ///   datetime head decodes an offset from it.
    public func extract(from text: String, schema: Schema,
                        now: Date = Date()) async throws -> Extraction {
        try schema.validate()
        let model = try await model.value()
        // One extraction is one billed call, however many fields and graph
        // runs it takes (four to six runs per field).
        return try await InferenceContext.withCallGroup {
            try await model.extract(from: text, schema: schema, now: now)
        }
    }

    /// An array of objects with an explicit segment anchor, for conformance
    /// testing against the reference (see `Model.objects`).
    func objects(text: String, properties: [Field], anchor: String,
                 trustedAnchor: Bool) async throws -> Value {
        let model = try await model.value()
        return try await model.objects(text: text, properties: properties, anchor: anchor,
                                       trustedAnchor: trustedAnchor)
    }

    /// Head-level intermediates for one field, for conformance testing.
    /// Not part of the stable surface.
    func trace(text: String, field: Field, anchor: String,
                      resolveAnchor: DateComponents? = nil,
                      trustedAnchor: Bool = true) async throws -> Model.FieldTrace {
        try await model.value().trace(text: text, field: field, anchor: anchor,
                                      resolveAnchor: resolveAnchor,
                                      trustedAnchor: trustedAnchor)
    }
}

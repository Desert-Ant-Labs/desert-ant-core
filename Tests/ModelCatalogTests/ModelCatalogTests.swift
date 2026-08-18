import Foundation
import Testing
import DesertAnt
@testable import Emo
@testable import Redact
@testable import Clear
@testable import Uhm
@testable import Tongue

/// Every model in the monorepo. The list lives here rather than beside the
/// `ModelDeclaration` protocol because each model's module depends on the
/// catalog's shared half, so the shared half cannot name them back. Tooling that
/// needs a registry (docs, go-live checks) can read this one.
let catalog: [any ModelDeclaration.Type] = [
    EmoModel.self,
    RedactModel.self,
    ClearModel.self,
    UhmModel.self,
    TongueModel.self,
]

/// Invariants every catalog entry must hold, so a malformed declaration fails
/// here rather than at download time inside one SDK.
struct ModelCatalogTests {
    @Test func everyEntryHasWellFormedCoordinates() {
        for model in catalog {
            #expect(model.id == model.id.lowercased() && !model.id.isEmpty)
            #expect(model.repo == "desert-ant-labs/\(model.id)")
            // A v-tag; or, for a model whose latest tag lacks one of its
            // platform artifacts, a documented pin of `main` itself or a full
            // commit hash of it (immutable, unlike the branch - clear pins the
            // commit carrying the ANE-shaped Core ML export until it is tagged).
            let isCommitHash = model.revision.count == 40 && model.revision.allSatisfy(\.isHexDigit)
            #expect(model.revision.hasPrefix("v") || model.revision == "main" || isCommitHash,
                    "\(model.id): revision must be a v-tag (or a documented main/commit pin)")
            #expect(model.product.first?.isUppercase == true, "\(model.id): product is capitalized")
            #expect(!model.summary.isEmpty)
        }
    }

    @Test func idsAreUnique() {
        let ids = catalog.map { $0.id }
        #expect(Set(ids).count == ids.count)
    }

    /// A model's `sdkVersion` is what its usage attributes to, and it is declared
    /// here rather than read from the package files (Swift cannot see them at
    /// build time), so this test is what keeps the three copies honest. It has
    /// caught real drift: Emo shipped 0.10.2 to npm and Maven while reporting
    /// 0.7.0 in its telemetry.
    @Test func sdkVersionsMatchThePublishedPackages() throws {
        for model in catalog {
            #expect(
                model.sdkVersion.split(separator: ".").count == 3,
                "\(model.id): sdkVersion must be X.Y.Z, got '\(model.sdkVersion)'")
            #expect(
                model.sdkInfo == SDKInfo(name: model.product, version: model.sdkVersion),
                "\(model.id): usage identity must derive from the declaration")

            if let npm = try packageVersion(model, "packages/\(model.id)-node/package.json") {
                #expect(
                    npm == model.sdkVersion,
                    "\(model.id): npm package is \(npm), catalog says \(model.sdkVersion)")
            }
            if let maven = try packageVersion(model, "packages/\(model.id)-kotlin/build.gradle.kts") {
                #expect(
                    maven == model.sdkVersion,
                    "\(model.id): Maven module is \(maven), catalog says \(model.sdkVersion)")
            }
        }
    }

    /// Every platform a model claims must list files, and the artifact it runs
    /// there must be one of them (as a file or as a `dir/` entry).
    @Test func manifestsContainTheirArtifact() {
        for model in catalog {
            #expect(!model.files.isEmpty, "\(model.id): no platform manifests")
            for (platform, files) in model.files {
                #expect(!files.isEmpty, "\(model.id)/\(platform.rawValue): empty manifest")
                let artifact = model.artifact(for: platform)
                #expect(
                    files.contains(artifact) || files.contains(artifact + "/"),
                    "\(model.id)/\(platform.rawValue): manifest is missing artifact \(artifact)"
                )
                #expect(Set(files).count == files.count, "\(model.id)/\(platform.rawValue): duplicate entries")
            }
        }
    }

    /// The catalog id is the last fact an npm package still restates: the native
    /// `dal_*` ABI takes it as an argument, so the JS side has to know it. (The
    /// wasm side no longer does - a core reports its own `modelInfo()`, and the
    /// host it drives arrives as an import rather than a named global.)
    @Test func jsPackagesUseTheDeclaredId() throws {
        for model in catalog {
            guard let codec = try packageFile("packages/\(model.id)-node/codec.js") else { continue }
            #expect(
                codec.contains("MODEL_ID = \"\(model.id)\""),
                "\(model.id): codec.js does not use the catalog id")
            #expect(
                !codec.contains("MODEL_FILES"),
                "\(model.id): codec.js restates file names the core reports itself")
        }
    }

    @Test func distributionCarriesTheDeclaration() {
        #expect(RedactModel.distribution.repo == "desert-ant-labs/redact")
        #expect(RedactModel.distribution.revision == RedactModel.revision)
        #expect(RedactModel.distribution.files[.apple] == RedactModel.files[.apple])
        #expect(RedactModel.artifact(for: .apple) == RedactModel.coreML)
        #expect(EmoModel.artifact(for: .android) == EmoModel.tflite)
        #expect(EmoModel.supports(.web))
    }
}

/// The first `X.Y.Z` on a `version` line of a package manifest, or nil when the
/// file is not reachable (a wasm/sandboxed run, or a package pruned from a
/// checkout) - the invariants above still run, only the cross-check is skipped.
private func packageVersion(_ model: any ModelDeclaration.Type, _ relativePath: String) throws -> String? {
    guard let text = try packageFile(relativePath) else { return nil }
    // Only the module's own version line counts. Anchoring on the start of the
    // line matters: `build.gradle.kts` also carries the convention plugin's
    // version (`id("ai.desertant.model-sdk") version "0.4.2"`), which a looser
    // "any line mentioning version" match picks up first.
    for raw in text.split(separator: "\n") {
        let line = raw.drop { $0 == " " || $0 == "\t" }
        guard line.hasPrefix("version") || line.hasPrefix("\"version\"") else { continue }
        if let found = firstSemanticVersion(in: line) { return found }
    }
    return nil
}

/// A repo file's contents, or nil when it is not reachable (a wasm/sandboxed
/// run, or a package pruned from a checkout) - the invariants still run, only
/// the cross-check is skipped.
private func packageFile(_ relativePath: String) throws -> String? {
    // #filePath is Tests/ModelCatalogTests/<file>, so the repo root is two up.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

/// The first `X.Y.Z` run in `line`. Hand-scanned rather than a regex literal:
/// this package builds in language mode 5, where bare `/.../` literals are off.
private func firstSemanticVersion(in line: Substring) -> String? {
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        guard chars[i].isNumber, i == 0 || !chars[i - 1].isNumber else { i += 1; continue }
        var j = i
        var dots = 0
        while j < chars.count, chars[j].isNumber || chars[j] == "." {
            if chars[j] == "." { dots += 1 }
            j += 1
        }
        let candidate = String(chars[i..<j])
        if dots == 2, !candidate.hasSuffix("."), candidate.split(separator: ".").count == 3 {
            return candidate
        }
        i = j + 1
    }
    return nil
}

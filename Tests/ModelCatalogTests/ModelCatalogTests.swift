import Testing
import DesertAnt
@testable import Emo
@testable import Redact

/// Every model in the monorepo. The list lives here rather than beside the
/// `ModelDeclaration` protocol because each model's module depends on the
/// catalog's shared half, so the shared half cannot name them back. Tooling that
/// needs a registry (docs, go-live checks) can read this one.
let catalog: [any ModelDeclaration.Type] = [
    EmoModel.self,
    RedactModel.self,
]

/// Invariants every catalog entry must hold, so a malformed declaration fails
/// here rather than at download time inside one SDK.
struct ModelCatalogTests {
    @Test func everyEntryHasWellFormedCoordinates() {
        for model in catalog {
            #expect(model.id == model.id.lowercased() && !model.id.isEmpty)
            #expect(model.repo == "desert-ant-labs/\(model.id)")
            #expect(model.revision.hasPrefix("v"), "\(model.id): revision must be a v-tag")
            #expect(model.product.first?.isUppercase == true, "\(model.id): product is capitalized")
            #expect(!model.summary.isEmpty)
        }
    }

    @Test func idsAreUnique() {
        let ids = catalog.map { $0.id }
        #expect(Set(ids).count == ids.count)
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

    @Test func distributionCarriesTheDeclaration() {
        #expect(RedactModel.distribution.repo == "desert-ant-labs/redact")
        #expect(RedactModel.distribution.revision == RedactModel.revision)
        #expect(RedactModel.distribution.files[.apple] == RedactModel.files[.apple])
        #expect(RedactModel.artifact(for: .apple) == RedactModel.coreML)
        #expect(EmoModel.artifact(for: .android) == EmoModel.tflite)
        #expect(EmoModel.supports(.web))
    }
}

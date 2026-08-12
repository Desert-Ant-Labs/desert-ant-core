// The semver selection behind ranged revision requirements: which published
// tag (or cached revision) a requirement lands on, and what never qualifies.

import Testing
@testable import ModelStore

struct RevisionRequirementTests {

    /// `exact` matches only itself - it is a ref, not a version.
    @Test func exactMatchesOnlyItself() {
        let r = RevisionRequirement.exact("v0.2.0")
        #expect(r.bestMatch(in: ["v0.1.0", "v0.2.0", "v0.3.0"]) == "v0.2.0")
        #expect(r.bestMatch(in: ["v0.3.0"]) == nil)
        #expect(r.exactRevision == "v0.2.0")
    }

    /// `from` picks the highest tag >= from within the same major (SwiftPM's
    /// from: semantics): from v0.2.0, the newest v0.x - never v1.0.0, never an
    /// older v0.1.
    @Test func fromStaysWithinTheMajor() {
        let r = RevisionRequirement.from("v0.2.0")
        #expect(r.bestMatch(in: ["v0.1.0", "v0.2.0", "v0.2.1", "v0.10.0", "v1.0.0"]) == "v0.10.0")
        #expect(r.bestMatch(in: ["v0.1.0", "v1.0.0"]) == nil)   // nothing in range
        #expect(r.exactRevision == nil)
    }

    /// Numeric ordering, not lexicographic: v0.10.0 > v0.9.0.
    @Test func ordersNumerically() {
        let r = RevisionRequirement.from("v0.9.0")
        #expect(r.bestMatch(in: ["v0.9.0", "v0.10.0"]) == "v0.10.0")
    }

    /// Branches, commits, and prerelease tags never satisfy a range; bare and
    /// shortened version tags do (v1 == 1.0.0).
    @Test func onlySemverTagsQualify() {
        let r = RevisionRequirement.from("1.0.0")
        #expect(r.bestMatch(in: ["main", "deadbeef", "v1.1.0-rc.1", "v1.1"]) == "v1.1")
        #expect(SemanticVersion(tag: "main") == nil)
        #expect(SemanticVersion(tag: "v1.2.3-beta") == nil)
        #expect(SemanticVersion(tag: "v1") == SemanticVersion(tag: "1.0.0"))
    }
}

extension SemanticVersion: Equatable {
    static func == (a: SemanticVersion, b: SemanticVersion) -> Bool { !(a < b) && !(b < a) }
}

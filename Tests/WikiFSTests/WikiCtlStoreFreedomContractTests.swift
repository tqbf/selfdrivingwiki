import Foundation
import Testing

/// CLI daemon-only freedom guard (plans/daemon-only-access.md Phase 0).
/// The shipping `wikictl` target and `WikiCtlCore` are already daemon-only
/// (plans/cli-domain-commands.md Phase 5), so this guard is clean from day
/// one — with an EMPTY waiver list. `wikictl-fixture` is the documented
/// build-only carve-out: it deliberately keeps a local database and is
/// excluded from the guarded set (asserted below so an accidental move back
/// under a guarded directory fails loudly).
struct WikiCtlStoreFreedomContractTests {
    @Test("shipping CLI sources contain no local storage constructions (zero waivers)")
    func cliSourcesAreClean() throws {
        try StoreFreedomGuardSupport.assertForbiddenTokens(
            guardedDirectories: ["Sources/WikiCtlCore", "Sources/wikictl"],
            guardedFiles: [],
            waivers: [])
    }

    @Test("wikictl-fixture remains the documented carve-out outside the guarded set")
    func fixtureCarveOutStaysExcluded() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtureMarker = root.appendingPathComponent(
            "Sources/wikictl-fixture/ExtractorFixtureLeg.swift")
        #expect(
            FileManager.default.fileExists(atPath: fixtureMarker.path),
            "wikictl-fixture moved — re-check the carve-out exclusions in WikiCtlStoreFreedomContractTests and the fixture's own suppression note")
    }
}

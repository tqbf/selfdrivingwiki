import Foundation
import Testing

/// File Provider daemon-only freedom guard (plans/daemon-only-access.md
/// Phase 0 → Phase 6). The extension reads the wiki database through
/// `GRDBWikiStore(readOnlyURL:)` today (waived); Phase 6 moves the
/// projection onto the daemon domain socket and this list becomes empty.
struct FileProviderStoreFreedomContractTests {
    static let waivers: [StoreFreedomGuardSupport.Waiver] = [
        StoreFreedomGuardSupport.Waiver(
            file: "Sources/WikiFSFileProvider/Projection.swift",
            token: "GRDBWikiStore(readOnlyURL:",
            count: 2,
            clearedIn: "P6"),
    ]

    @Test("File Provider sources declare every local storage construction with an exact waiver")
    func fileProviderSourcesMatchWaiverColumn() throws {
        try StoreFreedomGuardSupport.assertForbiddenTokens(
            guardedDirectories: ["Sources/WikiFSFileProvider"],
            guardedFiles: [],
            waivers: Self.waivers)
    }
}

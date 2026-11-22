import Foundation
import Testing

/// File Provider daemon-only freedom guard (plans/daemon-only-access.md
/// Phase 0 → Phase 6). Since Phase 6 the projection reads through the
/// daemon's read-only `projection` family over the domain socket — the
/// extension opens NO local storage, and this list is EMPTY (the P6
/// column of the permitted-access table).
struct FileProviderStoreFreedomContractTests {
    static let waivers: [StoreFreedomGuardSupport.Waiver] = []

    @Test("File Provider sources declare every local storage construction with an exact waiver")
    func fileProviderSourcesMatchWaiverColumn() throws {
        try StoreFreedomGuardSupport.assertForbiddenTokens(
            guardedDirectories: ["Sources/WikiFSFileProvider"],
            guardedFiles: [],
            waivers: Self.waivers)
    }
}

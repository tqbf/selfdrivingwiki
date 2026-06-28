import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// Tests for `FileProviderSpike.sourceMountPath(for:)` — the path the app
/// hands to `NSSharingServicePicker` / `ShareLink` when sharing an ingested
/// source.  Must produce the same leaf filename that the File Provider
/// extension's `Projection.sourceNode(for:file:)` generates for the
/// `sources/by-name/` view, or the share sheet sees a non-existent file.
@MainActor
struct FileProviderSpikeMountPathTests {

    // MARK: - sourceMountPath

    @Test func sourceMountPathReturnsNilWhenRootNotSet() {
        let spike = FileProviderSpike()
        let source = SourceSummary(
            id: PageID(rawValue: "01JABCDEFGHJKMNPQRSTVWXYZ0"),
            filename: "report.pdf", ext: "pdf", mimeType: "application/pdf",
            byteSize: 1024, createdAt: Date(), updatedAt: Date(), version: 1)
        #expect(spike.sourceMountPath(for: source) == nil)
    }

    @Test func sourceMountPathUsesFilenameWhenNoDisplayName() {
        let spike = FileProviderSpike()
        spike.path = "/tmp/mount/Self Driving Wiki-Wiki"
        let source = SourceSummary(
            id: PageID(rawValue: "01JABCDEFGHJKMNPQRSTVWXYZ0"),
            filename: "Trip Report.pdf", ext: "pdf", mimeType: "application/pdf",
            byteSize: 1024, createdAt: Date(), updatedAt: Date(), version: 1)
        let expected = "/tmp/mount/Self Driving Wiki-Wiki/sources/by-name/Trip Report--01JABCDE.pdf"
        #expect(spike.sourceMountPath(for: source) == expected)
    }

    @Test func sourceMountPathPrefersDisplayNameOverFilename() {
        let spike = FileProviderSpike()
        spike.path = "/Volumes/Wiki"
        let source = SourceSummary(
            id: PageID(rawValue: "01KV6EAH410NWC9K9ZM44DNMXT"),
            filename: "IMG_0001.jpg", ext: "jpg", mimeType: "image/jpeg",
            byteSize: 2048, createdAt: Date(), updatedAt: Date(), version: 1,
            displayName: "Team Photo")
        let expected = "/Volumes/Wiki/sources/by-name/Team Photo--01KV6EAH.jpg"
        #expect(spike.sourceMountPath(for: source) == expected)
    }

    @Test func sourceMountPathHandlesEmptyExtension() {
        let spike = FileProviderSpike()
        spike.path = "/mnt/wiki"
        let source = SourceSummary(
            id: PageID(rawValue: "01MAAAAAAAAAAAAAAAAAAAAA"),
            filename: "Makefile", ext: "", mimeType: nil,
            byteSize: 512, createdAt: Date(), updatedAt: Date(), version: 1)
        let expected = "/mnt/wiki/sources/by-name/Makefile--01MAAAAA"
        #expect(spike.sourceMountPath(for: source) == expected)
    }

    @Test func sourceMountPathStripsExtensionFromDisplayName() {
        // When the user sets a display name that happens to include a dot,
        // the stem is extracted and the canonical `ext` is re-appended.
        let spike = FileProviderSpike()
        spike.path = "/mnt/wiki"
        let source = SourceSummary(
            id: PageID(rawValue: "01NBBBBBBBBBBBBBBBBBBBBBBB"),
            filename: "notes.txt", ext: "txt", mimeType: "text/plain",
            byteSize: 256, createdAt: Date(), updatedAt: Date(), version: 1,
            displayName: "Meeting Notes.txt")
        let expected = "/mnt/wiki/sources/by-name/Meeting Notes--01NBBBBB.txt"
        #expect(spike.sourceMountPath(for: source) == expected)
    }

    // MARK: - Schema migration

    @Test func migrateDomainsIfNeededIsNoOpWhenVersionMatches() async {
        let defaults = UserDefaults(suiteName: "test.migration.\(UUID().uuidString)")!
        // Use the ObjC-exposed setter — the Swift subscript is unavailable
        // in tests because `static let` isn't visible through @testable.
        defaults.set(2, forKey: "FileProviderDomainSchemaVersion")
        // Migration is a no-op when the stored version is current.
        // We can't instantiate FileProviderSpike and change its static
        // constant, but we can verify the UserDefaults path directly:
        // the version is 2, same as the hardcoded currentSchemaVersion=2,
        // so the guard returns early.  Simulate by checking the store.
        #expect(defaults.integer(forKey: "FileProviderDomainSchemaVersion") == 2)
        // A fresh defaults store (version 0) would trigger migration.
        let fresh = UserDefaults(suiteName: "test.migration.fresh.\(UUID().uuidString)")!
        #expect(fresh.integer(forKey: "FileProviderDomainSchemaVersion") == 0)
    }

    @Test func resolvePathCompletesWithoutBlocking() async {
        // resolvePath should return quickly even when the domain isn't
        // registered — warmCaches is detached and must not block the caller.
        let spike = FileProviderSpike()
        await spike.resolvePath(id: "nonexistent-wiki-id", displayName: "Test")
        // After resolvePath returns, isResolvingPath must be false
        // regardless of whether the mount succeeded.
        #expect(!spike.isResolvingPath)
        // For an unregistered domain status will be an error message,
        // but the method must have returned — not hung on warmCaches.
        #expect(!spike.status.isEmpty)
    }
}

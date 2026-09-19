import Foundation
import Testing
@testable import WikiFSCore

/// `ZoteroConfig` load/save round-trip, defaulting, and attachment-key
/// validation — mirrors `WikiRegistryTests`'s temp-directory pattern.
struct ZoteroConfigTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-config-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savesAndLoadsRoundTrip() throws {
        let dir = tempDirectory()
        var config = ZoteroConfig()
        config.libraryID = "7089244"
        config.attachments = ["ABCD1234", "WXYZ5678"]
        try config.save(to: dir)

        let loaded = ZoteroConfig.load(from: dir)
        #expect(loaded == config)
        #expect(loaded.attachments == ["ABCD1234", "WXYZ5678"])
    }

    @Test func missingFileLoadsEmptyAndUnconfigured() {
        let config = ZoteroConfig.load(from: tempDirectory())
        #expect(config.libraryID == nil)
        #expect(config.attachments.isEmpty)
        #expect(!config.isConfigured)
    }

    @Test func corruptFileLoadsEmpty() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent(ZoteroConfig.fileName, isDirectory: false)
        try Data("not json".utf8).write(to: url)
        let config = ZoteroConfig.load(from: dir)
        #expect(!config.isConfigured)
    }

    @Test func isConfiguredRequiresNonEmptyLibraryID() {
        #expect(!ZoteroConfig(libraryID: nil).isConfigured)
        #expect(!ZoteroConfig(libraryID: "   ").isConfigured)
        #expect(ZoteroConfig(libraryID: "7089244").isConfigured)
    }

    /// The retired local-storage key is decode-tolerant but never re-written:
    /// an old file carrying `zoteroDirOverride` loads, and the re-encoded
    /// file drops the key entirely.
    @Test func retiredDirOverrideDecodesButIsNeverEncoded() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent(ZoteroConfig.fileName, isDirectory: false)
        let legacyJSON = """
        {
          "libraryID" : "7089244",
          "zoteroDirOverride" : "/Volumes/External/Zotero",
          "attachments" : ["ABCD1234"]
        }
        """
        try Data(legacyJSON.utf8).write(to: url)

        let loaded = ZoteroConfig.load(from: dir)
        #expect(loaded.libraryID == "7089244")
        #expect(loaded.zoteroDirOverride == "/Volumes/External/Zotero")
        #expect(loaded.attachments == ["ABCD1234"])

        try loaded.save(to: dir)
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(!rewritten.contains("zoteroDirOverride"))

        // Re-loading the rewritten file: the retired key is gone, the rest
        // round-trips.
        let reloaded = ZoteroConfig.load(from: dir)
        #expect(reloaded.zoteroDirOverride == nil)
        #expect(reloaded.libraryID == "7089244")
        #expect(reloaded.attachments == ["ABCD1234"])
    }

    @Test func roundTripPreservesNilFields() throws {
        let dir = tempDirectory()
        let config = ZoteroConfig(libraryID: nil)
        try config.save(to: dir)

        let loaded = ZoteroConfig.load(from: dir)
        #expect(loaded.libraryID == nil)
        #expect(loaded.attachments.isEmpty)
        #expect(!loaded.isConfigured)
    }

    @Test func saveThenReloadConfigIsRoundTripConsistent() throws {
        let dir = tempDirectory()
        // Save a configured config, then load it fresh and verify equality.
        let config = ZoteroConfig(libraryID: "7089244", attachments: ["ABCD1234"])
        try config.save(to: dir)

        let loaded = ZoteroConfig.load(from: dir)
        #expect(loaded == config)
    }

    // MARK: - Attachment-key validation

    @Test func attachmentKeyValidationAcceptsEightCharUppercaseKeys() {
        #expect(ZoteroConfig.attachmentKeyInvalidReason("ABCD1234") == nil)
        #expect(ZoteroConfig.attachmentKeyInvalidReason("9Z8Y7X6W") == nil)
    }

    @Test func attachmentKeyValidationRejectsMalformedKeysWithAMessage() {
        // 7 chars, 9 chars, lowercase, non-alphabet characters — each must
        // fail with a non-empty caller-facing message.
        for key in ["ABCD123", "ABCD12345", "abcd1234", "ABCD-123", "ABCD 123"] {
            let reason = ZoteroConfig.attachmentKeyInvalidReason(key)
            #expect(reason != nil, "expected \(key) to be rejected")
            #expect(reason?.isEmpty == false)
        }
    }

    @Test func validatedAttachmentsRejectsMalformedKeys() {
        #expect(throws: ZoteroConfigError.self) {
            try ZoteroConfig.validatedAttachments(["ABCD123"])
        }
        #expect(throws: ZoteroConfigError.self) {
            try ZoteroConfig.validatedAttachments(["abcd1234"])
        }
    }

    @Test func validatedAttachmentsRejectsDuplicateKeys() {
        #expect(throws: ZoteroConfigError.duplicateAttachmentKey("ABCD1234")) {
            try ZoteroConfig.validatedAttachments(["ABCD1234", "WXYZ5678", "ABCD1234"])
        }
    }

    @Test func validatedAttachmentsPreservesInputOrder() throws {
        let keys = ["ZZZZ9999", "AAAA0000", "Q7W8E9R0"]
        let validated = try ZoteroConfig.validatedAttachments(keys)
        #expect(validated == keys)
    }
}

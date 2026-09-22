import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// `ExtractorSyncSidecar.load(declaration:from:)` — the declared-field JSON
/// loader: required-field gates, pattern/length/alphabet item validation,
/// unknown-key tolerance, and the deliberate strictness deltas (duplicate
/// items hard-fail at load; items are validated against the declaration
/// even though the previous engine validated nothing in production).
struct ExtractorSyncSidecarTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-syncsidecar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The zotero-shaped declaration (same bounds the reviewed package
    /// declares): one required field, one required 8×A–Z0–9 list.
    private func zoteroShapedDeclaration(
        configFileName: String = "zotero-config.json"
    ) throws -> ExtractorSyncDeclaration {
        try ExtractorSyncDeclaration(
            configFileName: configFileName,
            urlTemplate: "https://api.example.org/users/{libraryID}/items/{itemKey}/file",
            fields: [
                ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
                ExtractorSyncFieldDeclaration(name: "attachments", required: true, isList: true),
            ],
            itemValidation: ExtractorSyncItemValidation(
                minimumLength: 8, maximumLength: 8,
                alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
    }

    private func write(
        _ object: [String: Any], fileName: String, to directory: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try data.write(
            to: directory.appendingPathComponent(fileName, isDirectory: false),
            options: .atomic)
    }

    // MARK: - Happy path

    @Test func loadsDeclaredFieldsAndItems() throws {
        let dir = tempDirectory()
        try write(
            ["libraryID": "12345", "attachments": ["ABCD1234", "WXYZ9876"]],
            fileName: "zotero-config.json", to: dir)

        let values = try ExtractorSyncSidecar.load(
            declaration: zoteroShapedDeclaration(), from: dir)
        #expect(values.fieldValues == ["libraryID": "12345"])
        #expect(values.items == ["ABCD1234", "WXYZ9876"])
    }

    /// Unknown JSON keys are ignored: old config files that still carry
    /// retired keys (like the zotero local-storage override) keep loading.
    @Test func unknownKeysAreIgnored() throws {
        let dir = tempDirectory()
        try write(
            [
                "libraryID": "12345",
                "attachments": ["ABCD1234"],
                "zoteroDirOverride": "/retired/path",
                "anythingElse": ["nested"],
            ],
            fileName: "zotero-config.json", to: dir)

        let values = try ExtractorSyncSidecar.load(
            declaration: zoteroShapedDeclaration(), from: dir)
        #expect(values.fieldValues == ["libraryID": "12345"])
        #expect(values.items == ["ABCD1234"])
    }

    /// Values are trimmed; a blank required value counts as unconfigured.
    @Test func blankRequiredFieldIsUnconfigured() throws {
        let dir = tempDirectory()
        try write(
            ["libraryID": "  \n", "attachments": ["ABCD1234"]],
            fileName: "zotero-config.json", to: dir)

        #expect(
            throws: ExtractorSyncSidecarError.requiredFieldNotConfigured(
                field: "libraryID", configFileName: "zotero-config.json")) {
                _ = try ExtractorSyncSidecar.load(
                    declaration: zoteroShapedDeclaration(), from: dir)
            }
    }

    @Test func missingFileLoadsAsUnconfiguredRequiredField() throws {
        let dir = tempDirectory()
        #expect(
            throws: ExtractorSyncSidecarError.requiredFieldNotConfigured(
                field: "libraryID", configFileName: "zotero-config.json")) {
                _ = try ExtractorSyncSidecar.load(
                    declaration: zoteroShapedDeclaration(), from: dir)
            }
    }

    @Test func corruptFileLoadsAsUnconfiguredRequiredField() throws {
        let dir = tempDirectory()
        try Data("{not json".utf8).write(
            to: dir.appendingPathComponent("zotero-config.json", isDirectory: false))

        #expect(
            throws: ExtractorSyncSidecarError.requiredFieldNotConfigured(
                field: "libraryID", configFileName: "zotero-config.json")) {
                _ = try ExtractorSyncSidecar.load(
                    declaration: zoteroShapedDeclaration(), from: dir)
            }
    }

    @Test func emptyRequiredListFailsWithType() throws {
        let dir = tempDirectory()
        try write(
            ["libraryID": "12345", "attachments": []],
            fileName: "zotero-config.json", to: dir)

        #expect(
            throws: ExtractorSyncSidecarError.requiredListIsEmpty(
                field: "attachments", configFileName: "zotero-config.json")) {
                _ = try ExtractorSyncSidecar.load(
                    declaration: zoteroShapedDeclaration(), from: dir)
            }
    }

    // MARK: - Item validation (the deliberate strictness delta)

    @Test func itemsAreValidatedAgainstTheDeclaration() throws {
        let dir = tempDirectory()
        try write(
            ["libraryID": "12345", "attachments": ["SHORT1"]],
            fileName: "zotero-config.json", to: dir)

        #expect(throws: ExtractorSyncSidecarError.self) {
            _ = try ExtractorSyncSidecar.load(
                declaration: zoteroShapedDeclaration(), from: dir)
        }
    }

    @Test func itemValidationReasonsAreCallerFacing() throws {
        let dir = tempDirectory()
        try write(
            ["libraryID": "12345", "attachments": ["abcd1234"]],
            fileName: "zotero-config.json", to: dir)

        do {
            _ = try ExtractorSyncSidecar.load(
                declaration: zoteroShapedDeclaration(), from: dir)
            Issue.record("expected an invalid-item failure")
        } catch let error as ExtractorSyncSidecarError {
            guard case .invalidItem(let item, let reason) = error else {
                Issue.record("expected invalidItem, got \(error)")
                return
            }
            #expect(item == "abcd1234")
            #expect(reason.contains("alphabet"))
            #expect(error.errorDescription?.contains("abcd1234") == true)
        }
    }

    /// Duplicate items hard-fail at load — the save-time contract the old
    /// per-package validation was written for, now enforced at sync load
    /// too (the previous engine deduped silently in a second pass).
    @Test func duplicateItemsHardFail() throws {
        let dir = tempDirectory()
        try write(
            ["libraryID": "12345", "attachments": ["ABCD1234", "ABCD1234"]],
            fileName: "zotero-config.json", to: dir)

        #expect(throws: ExtractorSyncSidecarError.duplicateItem(item: "ABCD1234")) {
            _ = try ExtractorSyncSidecar.load(
                declaration: zoteroShapedDeclaration(), from: dir)
        }
    }

    @Test func patternBasedItemValidation() throws {
        let declaration = try ExtractorSyncDeclaration(
            configFileName: "pattern-config.json",
            urlTemplate: "https://api.example.org/{itemKey}",
            fields: [
                ExtractorSyncFieldDeclaration(name: "slugs", required: true, isList: true),
            ],
            itemValidation: ExtractorSyncItemValidation(
                minimumLength: 1, maximumLength: 64, pattern: "^[a-z0-9-]+$"))

        let dir = tempDirectory()
        try write(["slugs": ["good-slug", "9"]], fileName: "pattern-config.json", to: dir)
        let values = try ExtractorSyncSidecar.load(declaration: declaration, from: dir)
        #expect(values.items == ["good-slug", "9"])

        try write(["slugs": ["Good_Slug"]], fileName: "pattern-config.json", to: dir)
        #expect(throws: ExtractorSyncSidecarError.self) {
            _ = try ExtractorSyncSidecar.load(declaration: declaration, from: dir)
        }
    }

    @Test func fieldPatternValidation() throws {
        let declaration = try ExtractorSyncDeclaration(
            configFileName: "field-config.json",
            urlTemplate: "https://api.example.org/lib/{libraryID}/items/{itemKey}",
            fields: [
                ExtractorSyncFieldDeclaration(name: "libraryID", required: true, pattern: "^[0-9]{1,10}$"),
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
            ])

        let dir = tempDirectory()
        try write(
            ["libraryID": "0123456789", "items": ["whatever1"]],
            fileName: "field-config.json", to: dir)
        _ = try ExtractorSyncSidecar.load(declaration: declaration, from: dir)

        try write(
            ["libraryID": "not-numeric", "items": ["whatever1"]],
            fileName: "field-config.json", to: dir)
        #expect(
            throws: ExtractorSyncSidecarError.invalidFieldValue(
                field: "libraryID", reason: "value of libraryID does not match the declared pattern")) {
                _ = try ExtractorSyncSidecar.load(declaration: declaration, from: dir)
            }
    }

    @Test func typeMismatchesAreTyped() throws {
        let dir = tempDirectory()
        try write(
            ["libraryID": 12345, "attachments": ["ABCD1234"]],
            fileName: "zotero-config.json", to: dir)
        #expect(throws: ExtractorSyncSidecarError.fieldValueNotAString(field: "libraryID")) {
            _ = try ExtractorSyncSidecar.load(
                declaration: zoteroShapedDeclaration(), from: dir)
        }

        try write(
            ["libraryID": "12345", "attachments": "ABCD1234"],
            fileName: "zotero-config.json", to: dir)
        #expect(throws: ExtractorSyncSidecarError.listValueNotAnArray(field: "attachments")) {
            _ = try ExtractorSyncSidecar.load(
                declaration: zoteroShapedDeclaration(), from: dir)
        }

        try write(
            ["libraryID": "12345", "attachments": [7]],
            fileName: "zotero-config.json", to: dir)
        #expect(throws: ExtractorSyncSidecarError.itemNotAString(field: "attachments", index: 0)) {
            _ = try ExtractorSyncSidecar.load(
                declaration: zoteroShapedDeclaration(), from: dir)
        }
    }

    @Test func oversizeListFailsWithType() throws {
        let declaration = try ExtractorSyncDeclaration(
            configFileName: "many-config.json",
            urlTemplate: "https://api.example.org/{itemKey}",
            fields: [
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
            ])
        let dir = tempDirectory()
        let tooMany = (0..<(ExtractorHostLimits.maximumSyncItemCount + 1))
            .map { String(format: "%08d", $0) }
        try write(["items": tooMany], fileName: "many-config.json", to: dir)

        #expect(throws: ExtractorSyncSidecarError.tooManyItems(
            field: "items", count: tooMany.count)) {
            _ = try ExtractorSyncSidecar.load(declaration: declaration, from: dir)
        }
    }

    /// An optional absent field is simply missing from the values; an
    /// optional absent list syncs nothing (the engine's contract).
    @Test func optionalFieldsMayBeAbsent() throws {
        let declaration = try ExtractorSyncDeclaration(
            configFileName: "optional-config.json",
            urlTemplate: "https://api.example.org/lib/{libraryID}/items/{itemKey}",
            fields: [
                ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
                ExtractorSyncFieldDeclaration(name: "region", required: false),
                ExtractorSyncFieldDeclaration(name: "items", required: false, isList: true),
            ])
        let dir = tempDirectory()
        try write(["libraryID": "9"], fileName: "optional-config.json", to: dir)

        let values = try ExtractorSyncSidecar.load(declaration: declaration, from: dir)
        #expect(values.fieldValues == ["libraryID": "9"])
        #expect(values.items.isEmpty)
    }
}

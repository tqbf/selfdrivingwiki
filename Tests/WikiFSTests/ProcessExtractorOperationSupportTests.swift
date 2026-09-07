#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

/// The reviewed-only operation-support seam: exact-revision admission,
/// race-resistant staging, fail-closed path rules, owner-private permissions,
/// and cleanup on every terminal path. Also pins the tagged
/// operation-configuration envelope the staged grant rides in.
@Suite("Process extractor operation support", .timeLimit(.minutes(2)))
struct ProcessExtractorOperationSupportTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-opsupport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeTestDirectory(_ url: URL) {
        // Test cleanup must not hide the assertion result.
        // swiftlint:disable:next silent_try_optional
        try? FileManager.default.removeItem(at: url)
    }

    private func makeHelper(at url: URL, bytes: String = "#!/bin/sh\necho token\n") throws -> String {
        let data = Data(bytes.utf8)
        try data.write(to: url)
        return ExtractorSHA256.digest(data).hex
    }

    private func grant(
        source: URL,
        destination: String = "podcast-token-helper",
        sha256: String? = nil,
        byteCount: Int? = nil
    ) throws -> ExtractorOperationSupportGrant {
        let data = try Data(contentsOf: source)
        guard let grant = ExtractorOperationSupportGrant(
            role: .podcastTokenHelper,
            sourceURL: source,
            destinationFileName: destination,
            expectedSHA256: sha256 ?? ExtractorSHA256.digest(data).hex,
            expectedByteCount: byteCount ?? data.count) else {
            Issue.record("grant construction failed")
            throw ExtractorOperationSupportError.stagingFailed
        }
        return grant
    }

    // MARK: - Exact-revision admission (AC.6)

    #if PODCAST_TRANSCRIPTS
    @Test func directGrantMatchesFixtureIdentity() throws {
        let root = try tempDirectory()
        defer {
            // Test cleanup must not hide the assertion result.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: root)
        }
        let helper = root.appendingPathComponent("fixture-helper")
        let bytes = Data("fixture helper bytes".utf8)
        try bytes.write(to: helper)

        let grant = try #require(
            ReviewedApplePodcastSupportProvider.grant(helperURL: helper))
        #expect(grant.expectedSHA256 == ExtractorSHA256.digest(bytes).hex)
        #expect(grant.expectedByteCount == bytes.count)
        #expect(grant.destinationFileName.rawValue == "podcast-token-helper")
    }

    @Test func grantsExactReviewedRevisionOnly() throws {
        let root = try tempDirectory()
        defer {
            // Test cleanup must not hide the assertion result.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: root)
        }
        let helper = root.appendingPathComponent("fixture-helper")
        _ = try makeHelper(at: helper)
        let reviewed = ReviewedExtractorPackages.applePodcastTranscript.revision
        let provider = ReviewedApplePodcastSupportProvider(
            revision: reviewed, helperURLResolver: { helper })
        let lookalike = ExtractorPackageRevisionID(
            packageID: reviewed.packageID,
            version: reviewed.version,
            digest: try ExtractorPackageDigest(hex: String(repeating: "ab", count: 32)))

        #expect(provider.operationSupport(for: reviewed) != nil)
        #expect(provider.operationSupport(for: lookalike) == nil)
    }

    @Test func missingHelperIsASupportedNoGrantState() {
        let reviewed = ReviewedExtractorPackages.applePodcastTranscript.revision
        let provider = ReviewedApplePodcastSupportProvider(
            revision: reviewed, helperURLResolver: { nil })
        #expect(provider.operationSupport(for: reviewed) == nil)
    }
    #endif

    // MARK: - Staging (AC.7, AC.8)

    @Test func stagesOwnerOnlyExecutableAndCleansUp() throws {
        let root = try tempDirectory()
        defer { removeTestDirectory(root) }
        let source = root.appendingPathComponent("helper-source")
        let sha = try makeHelper(at: source)

        let staged = try ExtractorOperationSupportStager.stage(
            grant: try grant(source: source, sha256: sha),
            operationRoot: root,
            requestName: "req-1")

        let stagedURL = root.appendingPathComponent(staged.relativePath.rawValue)
        var status = stat()
        #expect(lstat(stagedURL.path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFREG)
        #expect(status.st_mode & 0o777 == 0o500)
        let expectedByteCount = try Data(contentsOf: source).count
        #expect(Int(status.st_size) == expectedByteCount)
        // Cleanup removes the whole request support directory.
        try FileManager.default.removeItem(at: staged.supportDirectoryURL)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path) == false)
    }

    @Test func rejectsSymlinkedSource() throws {
        let root = try tempDirectory()
        defer { removeTestDirectory(root) }
        let real = root.appendingPathComponent("real-helper")
        _ = try makeHelper(at: real)
        let link = root.appendingPathComponent("helper-source")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(throws: ExtractorOperationSupportError.self) {
            try ExtractorOperationSupportStager.stage(
                grant: try grant(source: link),
                operationRoot: root,
                requestName: "req-1")
        }
    }

    @Test func rejectsChangedSourceIdentity() throws {
        let root = try tempDirectory()
        defer { removeTestDirectory(root) }
        let source = root.appendingPathComponent("helper-source")
        let sha = try makeHelper(at: source)
        // Mutate AFTER computing the expected identity.
        try Data("tampered".utf8).write(to: source)

        #expect(throws: ExtractorOperationSupportError.self) {
            try ExtractorOperationSupportStager.stage(
                grant: try grant(source: source, sha256: sha),
                operationRoot: root,
                requestName: "req-1")
        }
    }

    @Test func rejectsHashMismatchDuringCopy() throws {
        let root = try tempDirectory()
        defer { removeTestDirectory(root) }
        let source = root.appendingPathComponent("helper-source")
        _ = try makeHelper(at: source)

        #expect(throws: ExtractorOperationSupportError.sourceHashMismatch) {
            try ExtractorOperationSupportStager.stage(
                grant: try grant(source: source, sha256: String(repeating: "0", count: 64)),
                operationRoot: root,
                requestName: "req-1")
        }
        // Failure cleanup removes the ENTIRE request support directory —
        // no unpublished temporary files, no partial destination.
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("support/req-1").path) == false,
            "staging failure must leave no support directory behind")
    }

    @Test func rejectsDestinationPathTraversalAndExistingDestination() throws {
        let root = try tempDirectory()
        defer { removeTestDirectory(root) }
        let source = root.appendingPathComponent("helper-source")
        let sha = try makeHelper(at: source)

        // A multi-component destination is rejected at grant construction.
        #expect(
            ExtractorOperationSupportGrant(
                role: .podcastTokenHelper,
                sourceURL: source,
                destinationFileName: "nested/dir/helper",
                expectedSHA256: sha,
                expectedByteCount: 0) == nil)

        // A pre-existing destination is never executed: the link refuses
        // EEXIST, and the failure cleanup then removes the whole request
        // support directory — planted file included.
        let support = root.appendingPathComponent("support/req-1")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("planted".utf8).write(to: support.appendingPathComponent("podcast-token-helper"))
        #expect(throws: ExtractorOperationSupportError.self) {
            try ExtractorOperationSupportStager.stage(
                grant: try grant(source: source, sha256: sha),
                operationRoot: root,
                requestName: "req-1")
        }
        #expect(
            FileManager.default.fileExists(
                atPath: support.appendingPathComponent("podcast-token-helper").path) == false,
            "the planted destination must not survive staging failure cleanup")
    }

    // MARK: - Tagged operation configuration (AC.7 shape)

    @Test func configurationEncodingRoundTripsBothCases() throws {
        let docling = try ExtractorOperationConfiguration(
            endpoint: "http://127.0.0.1:8000", timeoutMilliseconds: 600_000)
        let doclingData = try JSONEncoder().encode(docling)
        // The Docling case keeps the legacy flat wire shape.
        let doclingObject = try JSONSerialization.jsonObject(with: doclingData) as! [String: Any]
        #expect(doclingObject["kind"] == nil)
        #expect(doclingObject["endpoint"] as? String == "http://127.0.0.1:8000")

        let apple = ExtractorOperationConfiguration.applePodcastTranscript(
            helperPath: try ExtractorRelativePath(validating: "support/req/helper"))
        let appleData = try JSONEncoder().encode(apple)
        let appleObject = try JSONSerialization.jsonObject(with: appleData) as! [String: Any]
        #expect(appleObject["kind"] as? String == "apple-podcast-transcript")
        #expect(appleObject["helperPath"] as? String == "support/req/helper")

        // Round trips.
        #expect(try JSONDecoder().decode(ExtractorOperationConfiguration.self, from: doclingData) == docling)
        #expect(try JSONDecoder().decode(ExtractorOperationConfiguration.self, from: appleData) == apple)
    }

    @Test func configurationRejectsMixedUnknownAndInvalidShapes() throws {
        // Mixed: apple kind carrying a docling field.
        #expect(throws: ExtractorValidationError.self) {
            try JSONDecoder().decode(ExtractorOperationConfiguration.self, from: Data(#"""
            {"kind": "apple-podcast-transcript", "helperPath": "support/h", "endpoint": "http://x"}
            """#.utf8))
        }
        // Mixed: flat docling shape carrying a helper path.
        #expect(throws: ExtractorValidationError.self) {
            try JSONDecoder().decode(ExtractorOperationConfiguration.self, from: Data(#"""
            {"endpoint": "http://x", "helperPath": "support/h"}
            """#.utf8))
        }
        // Unknown field.
        #expect(throws: ExtractorValidationError.self) {
            try JSONDecoder().decode(ExtractorOperationConfiguration.self, from: Data(#"""
            {"kind": "apple-podcast-transcript", "helperPath": "h", "surprise": 1}
            """#.utf8))
        }
        // Unknown kind.
        #expect(throws: ExtractorValidationError.self) {
            try JSONDecoder().decode(ExtractorOperationConfiguration.self, from: Data(#"""
            {"kind": "other"}
            """#.utf8))
        }
        // Apple case without a helper path.
        #expect(throws: ExtractorValidationError.self) {
            try JSONDecoder().decode(ExtractorOperationConfiguration.self, from: Data(#"""
            {"kind": "apple-podcast-transcript"}
            """#.utf8))
        }
        // Apple helper path that traverses.
        #expect(throws: ExtractorValidationError.self) {
            try JSONDecoder().decode(ExtractorOperationConfiguration.self, from: Data(#"""
            {"kind": "apple-podcast-transcript", "helperPath": "../escape"}
            """#.utf8))
        }
        // Legacy flat shape still decodes (installed Docling v2 package).
        let legacy = try JSONDecoder().decode(
            ExtractorOperationConfiguration.self,
            from: Data(#"{"endpoint": "http://127.0.0.1:8000", "timeoutMilliseconds": 5}"#.utf8))
        #expect(legacy == .doclingServe(endpoint: "http://127.0.0.1:8000", timeoutMilliseconds: 5))
        for invalidLegacy in [
            #"{"endpoint": 5}"#,
            #"{"timeoutMilliseconds": "x"}"#,
        ] {
            #expect(throws: ExtractorValidationError.self) {
                try JSONDecoder().decode(
                    ExtractorOperationConfiguration.self,
                    from: Data(invalidLegacy.utf8))
            }
        }
        // Non-http endpoint is rejected in both construction paths.
        #expect(throws: ExtractorValidationError.self) {
            try ExtractorOperationConfiguration(endpoint: "file:///etc", timeoutMilliseconds: nil)
        }
    }
}
#endif

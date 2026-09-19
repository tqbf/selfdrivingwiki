import Foundation
import Testing
import WikiFSTypes

struct ExtractorProtocolTests {
    @Test func protocolRevision4IsAcceptedAnd5IsRejected() throws {
        #expect(ExtractorProtocolRevision(rawValue: 4) == .v4)
        #expect(ExtractorProtocolRevision(rawValue: 5) == nil)
        #expect(throws: Error.self) {
            try JSONDecoder().decode(
                ExtractorProtocolRevision.self,
                from: JSONEncoder().encode(5))
        }
        // Revision ordering: 1 < 2 < 3 < 4 (a rev-4 host still serves 1-3).
        #expect(ExtractorProtocolRevision.v1 < .v2)
        #expect(ExtractorProtocolRevision.v2 < .v3)
        #expect(ExtractorProtocolRevision.v3 < .v4)
    }

    /// AC.1: a revision-4 result frame with `resultMIMEType` and
    /// `articleMetadata.identifier` decodes and round-trips, and the
    /// Markdown-result discriminator follows the absent/text-markdown rule.
    @Test func revision4ResultFrameRoundTripsBytesShape() throws {
        let requestID = ExtractorRequestID()
        let output = try outputPath()
        let bytesFrame = try ExtractorResultFrame(
            requestID: requestID,
            outputPath: output,
            markdownByteCount: 11,
            articleMetadata: try ExtractorArticleMetadata(
                title: "A Paper",
                author: "Doe, J.; Roe, A.",
                published: "2024-05-01",
                identifier: "ABCD1234"),
            resultMIMEType: try ExtractorMIMEType(validating: "application/pdf"))
        #expect(bytesFrame.isMarkdownResult == false)

        let roundTrip = try JSONDecoder().decode(
            ExtractorResultFrame.self,
            from: JSONEncoder().encode(bytesFrame))
        #expect(roundTrip == bytesFrame)
        #expect(roundTrip.resultMIMEType?.rawValue == "application/pdf")
        #expect(roundTrip.articleMetadata?.identifier == "ABCD1234")

        // Absent and text/markdown both mean "the output IS the Markdown".
        let absent = try ExtractorResultFrame(
            requestID: requestID, outputPath: output, markdownByteCount: 1)
        #expect(absent.isMarkdownResult)
        let markdownMarked = try ExtractorResultFrame(
            requestID: requestID, outputPath: output, markdownByteCount: 1,
            resultMIMEType: try ExtractorMIMEType(validating: "text/markdown"))
        #expect(markdownMarked.isMarkdownResult)

        // Encoding omits both optional fields when absent.
        let bareJSON = String(decoding: try JSONEncoder().encode(absent), as: UTF8.self)
        #expect(bareJSON.contains("resultMIMEType") == false)

        // An invalid MIME value fails the decode.
        let invalidJSON = """
        {"requestID":"\(requestID.rawValue.uuidString.lowercased())","outputPath":"output/result.md","markdownByteCount":1,"resultMIMEType":"NOT A MIME"}
        """
        #expect(throws: Error.self) {
            try JSONDecoder().decode(ExtractorResultFrame.self, from: Data(invalidJSON.utf8))
        }
    }

    /// AC.1: a revision ≤ 3 request still round-trips unchanged, and a
    /// revision-4 remote-url request decodes (revision 4 only extends the
    /// result frame; the request wire shape is byte-for-byte revision 3).
    @Test func remoteURLRequestsDecodeForRevisions3And4() throws {
        let requestID = ExtractorRequestID()
        let deadline: Int64 = 1_735_689_600_000
        let v3 = try ExtractorProtocolRequest(
            requestID: requestID,
            protocolRevision: .v3,
            kind: .podcastTranscript,
            mimeType: try ExtractorMIMEType(validating: "audio/podcast"),
            originalFilename: "feed",
            remoteURL: try ExtractorRemoteSourceURL(validating: "https://example.com/feed.rss"),
            outputPath: try ExtractorRelativePath(validating: "output/result.md"),
            deadlineMillisecondsSince1970: deadline)
        let v4 = try ExtractorProtocolRequest(
            requestID: requestID,
            protocolRevision: .v4,
            kind: .podcastTranscript,
            mimeType: try ExtractorMIMEType(validating: "audio/podcast"),
            originalFilename: "feed",
            remoteURL: try ExtractorRemoteSourceURL(validating: "https://example.com/feed.rss"),
            outputPath: try ExtractorRelativePath(validating: "output/result.md"),
            deadlineMillisecondsSince1970: deadline)
        let decoder = JSONDecoder()
        for request in [v3, v4] {
            let roundTrip = try decoder.decode(
                ExtractorProtocolRequest.self,
                from: JSONEncoder().encode(request))
            #expect(roundTrip == request)
        }
        // Revisions 1 and 2 still reject the remote-url transport.
        let v3JSON = String(decoding: try JSONEncoder().encode(v3), as: UTF8.self)
        let v2JSON = v3JSON.replacing(
            "\"protocolRevision\":3", with: "\"protocolRevision\":2")
        #expect(throws: Error.self) {
            try decoder.decode(ExtractorProtocolRequest.self, from: Data(v2JSON.utf8))
        }
    }

    /// A revision ≤ 3 host fails closed: a result frame carrying the
    /// revision-4 fields is rejected by the sequence instead of silently
    /// decoded-and-dropped. The same frame is accepted for a revision-4
    /// request.
    @Test func sequenceRejectsRevision4ResultFieldsForOlderRevisions() throws {
        let requestID = ExtractorRequestID()
        let output = try outputPath()
        func bytesFrame() throws -> ExtractorProtocolFrame {
            .result(try ExtractorResultFrame(
                requestID: requestID,
                outputPath: output,
                markdownByteCount: 3,
                articleMetadata: try ExtractorArticleMetadata(identifier: "ABCD1234"),
                resultMIMEType: try ExtractorMIMEType(validating: "application/pdf")))
        }
        func sequence(_ revision: ExtractorProtocolRevision) -> ExtractorProtocolSequence {
            ExtractorProtocolSequence(
                requestID: requestID,
                expectedOutputPath: output,
                maximumProgressEventCount: 2,
                protocolRevision: revision)
        }
        // Default construction keeps the fail-closed older-host posture.
        var legacy = sequence(.v3)
        #expect(throws: ExtractorProtocolSequenceError.resultFieldsRequireProtocolRevision4) {
            try legacy.consume(try bytesFrame())
        }
        // An identifier alone is revision-4-only too.
        var legacyIdentifier = sequence(.v1)
        #expect(throws: ExtractorProtocolSequenceError.resultFieldsRequireProtocolRevision4) {
            try legacyIdentifier.consume(.result(try ExtractorResultFrame(
                requestID: requestID,
                outputPath: output,
                markdownByteCount: 3,
                articleMetadata: try ExtractorArticleMetadata(identifier: "ABCD1234"))))
        }
        // Revision 4 accepts the frame and terminates normally.
        var modern = sequence(.v4)
        try modern.consume(try bytesFrame())
        #expect(try modern.finish().isTerminal)
    }

    /// `articleMetadata.identifier` bounds: 1–1024 bytes, no NUL, no empty.
    @Test func articleMetadataIdentifierIsValidated() throws {
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(identifier: "")
        }
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(identifier: "bad\0value")
        }
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(identifier: String(repeating: "x", count: 1_025))
        }
        let ok = try ExtractorArticleMetadata(identifier: String(repeating: "x", count: 1_024))
        #expect(ok.identifier?.count == 1_024)
    }

    @Test func validProgressAndResultRoundTrip() throws {
        let requestID = ExtractorRequestID()
        let expectedOutputPath = try outputPath()
        let frames: [ExtractorProtocolFrame] = [
            .progress(try ExtractorProgressFrame(requestID: requestID, completedUnitCount: 1, totalUnitCount: 2, message: "reading")),
            .diagnostic(try ExtractorDiagnosticFrame(requestID: requestID, message: "fixture diagnostic")),
            .result(try ExtractorResultFrame(
                requestID: requestID,
                outputPath: expectedOutputPath,
                markdownByteCount: 42,
                warnings: ["one warning"],
                metadata: ExtractorReportedMetadata(toolName: "fixture", toolVersion: "1.0.0")))
        ]
        var sequence = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 2)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for frame in frames {
            let roundTrip = try decoder.decode(ExtractorProtocolFrame.self, from: encoder.encode(frame))
            #expect(roundTrip == frame)
            try sequence.consume(roundTrip)
        }
        #expect(try sequence.finish() == frames.last)
    }

    @Test func articleMetadataRoundTripsAndIsOmittedWhenAbsent() throws {
        let requestID = ExtractorRequestID()
        let expectedOutputPath = try outputPath()
        let metadata = try ExtractorArticleMetadata(
            title: "Example",
            author: "Jane Doe",
            description: "An example article",
            published: "2026-08-26",
            wordCount: 321)
        let populated = try ExtractorResultFrame(
            requestID: requestID,
            outputPath: expectedOutputPath,
            markdownByteCount: 10,
            articleMetadata: metadata)
        let roundTrip = try JSONDecoder().decode(
            ExtractorResultFrame.self,
            from: JSONEncoder().encode(populated))
        #expect(roundTrip.articleMetadata == metadata)

        let bare = try ExtractorResultFrame(
            requestID: requestID,
            outputPath: expectedOutputPath,
            markdownByteCount: 1)
        let bareJSON = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        #expect(bareJSON.contains("articleMetadata") == false)
        let bareRoundTrip = try JSONDecoder().decode(
            ExtractorResultFrame.self,
            from: JSONEncoder().encode(bare))
        #expect(bareRoundTrip.articleMetadata == nil)
    }

    @Test func rejectsInvalidArticleMetadata() throws {
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(title: "")
        }
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(title: String(repeating: "x", count: 2_048))
        }
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(wordCount: -1)
        }
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(wordCount: 10_000_001)
        }
    }

    @Test func rejectsMismatchedAndExcessProgress() throws {
        let requestID = ExtractorRequestID()
        let expectedOutputPath = try outputPath()
        var mismatch = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        #expect(throws: ExtractorProtocolSequenceError.requestMismatch) {
            try mismatch.consume(.progress(ExtractorProgressFrame(requestID: ExtractorRequestID())))
        }

        var excess = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        let progress = try ExtractorProtocolFrame.progress(ExtractorProgressFrame(requestID: requestID))
        try excess.consume(progress)
        #expect(throws: ExtractorProtocolSequenceError.tooManyProgressEvents) {
            try excess.consume(progress)
        }
    }

    @Test func rejectsDuplicateTerminalOutputAfterTerminalAndWrongOutputPath() throws {
        let requestID = ExtractorRequestID()
        let expectedOutputPath = try outputPath()
        let result = try ExtractorProtocolFrame.result(ExtractorResultFrame(
            requestID: requestID,
            outputPath: expectedOutputPath,
            markdownByteCount: 0))
        var duplicate = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        try duplicate.consume(result)
        #expect(throws: ExtractorProtocolSequenceError.duplicateTerminal) { try duplicate.consume(result) }

        var output = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        try output.consume(result)
        #expect(throws: ExtractorProtocolSequenceError.outputAfterTerminal) {
            try output.consume(.diagnostic(ExtractorDiagnosticFrame(requestID: requestID, message: "late")))
        }

        var wrongPath = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        let mismatchedResult = try ExtractorProtocolFrame.result(ExtractorResultFrame(
            requestID: requestID,
            outputPath: ExtractorRelativePath(validating: "output/other.md"),
            markdownByteCount: 0))
        #expect(throws: ExtractorProtocolSequenceError.outputPathMismatch) {
            try wrongPath.consume(mismatchedResult)
        }
    }

    @Test func missingTerminalAndInvalidRequestPathsAreRejected() throws {
        let requestID = ExtractorRequestID()
        let sequence = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: try outputPath(),
            maximumProgressEventCount: 1)
        #expect(throws: ExtractorProtocolSequenceError.missingTerminal) { _ = try sequence.finish() }
        #expect(throws: ExtractorValidationError.invalidManifest("input and output paths match")) {
            _ = try ExtractorProtocolRequest(
                requestID: requestID,
                protocolRevision: .v1,
                kind: .pdf,
                mimeType: ExtractorMIMEType(validating: "application/pdf"),
                originalFilename: "source.pdf",
                inputPath: ExtractorRelativePath(validating: "source.pdf"),
                outputPath: ExtractorRelativePath(validating: "source.pdf"),
                deadlineMillisecondsSince1970: 1)
        }
    }

    private func outputPath() throws -> ExtractorRelativePath {
        try ExtractorRelativePath(validating: "output/result.md")
    }
}

/// Protocol revision 3: the tagged operation input. Revision 3 accepts
/// `operation-file` and `remote-url`; revisions 1 and 2 keep their exact old
/// wire contract and reject the revision-3 key set.
struct ExtractorProtocolRevision3Tests {
    private func mimeType() throws -> ExtractorMIMEType {
        try ExtractorMIMEType(validating: "audio/podcast")
    }

    private func outputPath() throws -> ExtractorRelativePath {
        try ExtractorRelativePath(validating: "output/result.md")
    }

    @Test func remoteURLRevision3RoundTrip() throws {
        let request = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(rawValue: UUID(uuidString: "4f25e76a-be09-467f-b71e-68c02da4d16a")!),
            protocolRevision: .v3,
            kind: .podcastTranscript,
            mimeType: mimeType(),
            originalFilename: "feed",
            remoteURL: ExtractorRemoteSourceURL(validating: "https://example.com/feed.rss"),
            outputPath: outputPath(),
            deadlineMillisecondsSince1970: 1)

        #expect(request.inputTransport == .remoteURL)
        #expect(request.inputPath == nil)
        #expect(request.remoteURL?.rawValue == "https://example.com/feed.rss")
        guard case .remoteURL(let url) = request.operationInput else {
            Issue.record("expected a remote-url operation input")
            return
        }
        #expect(url.rawValue == "https://example.com/feed.rss")

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtractorProtocolRequest.self, from: data)
        #expect(decoded == request)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["inputTransport"] as? String == "remote-url")
        #expect(object["remoteURL"] as? String == "https://example.com/feed.rss")
        #expect(object["inputPath"] == nil)
    }

    /// Revision-3 packages may also use the classic operation-file transport.
    @Test func revision3AcceptsOperationFileTransport() throws {
        let request = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(),
            protocolRevision: .v3,
            kind: .pdf,
            mimeType: ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "source.pdf",
            inputPath: ExtractorRelativePath(validating: "input/source"),
            outputPath: outputPath(),
            deadlineMillisecondsSince1970: 1)
        #expect(request.inputTransport == .operationFile)
        #expect(request.remoteURL == nil)

        let decoded = try JSONDecoder().decode(
            ExtractorProtocolRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    /// Immutable v1/v2 golden fixtures: the old wire shape decodes exactly,
    /// and the equivalent typed request encodes to the same key set with
    /// identical values — nothing is dropped, added, or renamed. (Foundation
    /// JSONEncoder does not preserve key order, so the comparison is over the
    /// parsed objects, not raw bytes.)
    @Test func legacyRevisionBytesDecodeAndReencodeExactly() throws {
        let requestID = "4f25e76a-be09-467f-b71e-68c02da4d16a"
        let legacyV1 = """
        {"requestID":"\(requestID)","protocolRevision":1,"kind":"pdf","mimeType":"application/pdf","originalFilename":"source.pdf","inputTransport":"operation-file","inputPath":"input/source","outputPath":"output/result.md","deadlineMillisecondsSince1970":1}
        """
        let legacyV2 = """
        {"requestID":"\(requestID)","protocolRevision":2,"kind":"pdf","mimeType":"application/pdf","originalFilename":"source.pdf","inputTransport":"operation-file","inputPath":"input/source","outputPath":"output/result.md","deadlineMillisecondsSince1970":1,"credentialFilePath":"credentials/request/input.json","operationConfigurationPath":"config/request/operation.json"}
        """
        let expectedKeys: [String] = [
            "requestID", "protocolRevision", "kind", "mimeType", "originalFilename",
            "inputTransport", "inputPath", "outputPath", "deadlineMillisecondsSince1970",
        ]
        let expectedV2Keys = expectedKeys + ["credentialFilePath", "operationConfigurationPath"]

        let stagedPath = try ExtractorRelativePath(validating: "input/source")
        for (legacy, revision, keys) in [
            (legacyV1, ExtractorProtocolRevision.v1, expectedKeys),
            (legacyV2, .v2, expectedV2Keys),
        ] {
            let legacyObject = try #require(
                JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any])
            #expect(Set(legacyObject.keys) == Set(keys))

            let decoded = try JSONDecoder().decode(
                ExtractorProtocolRequest.self, from: Data(legacy.utf8))
            #expect(decoded.protocolRevision == revision)
            #expect(decoded.inputTransport == .operationFile)
            #expect(decoded.remoteURL == nil)
            #expect(decoded.inputPath == stagedPath)
            #expect(decoded.operationInput == .operationFile(stagedPath))

            let reencodedObject = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(decoded)) as? [String: Any])
            let legacyAsValue = try #require(legacyObject as? [String: NSObject])
            let reencodedAsValue = try #require(reencodedObject as? [String: NSObject])
            #expect(reencodedAsValue == legacyAsValue)
        }
    }

    /// Revisions 1 and 2 reject the revision-3 key set: a `remoteURL` key, a
    /// `remote-url` transport, and any mixed shape.
    @Test func legacyRevisionsRejectRevision3KeysAndTransports() throws {
        let requestID = "4f25e76a-be09-467f-b71e-68c02da4d16a"
        let strayKey = ",\"remoteURL\":\"https://example.com/feed.rss\""

        // A stray remoteURL key on an operation-file request: rejected for
        // every revision.
        for revision in [1, 2, 3] {
            let document = """
            {"requestID":"\(requestID)","protocolRevision":\(revision),"kind":"pdf","mimeType":"application/pdf","originalFilename":"source.pdf","inputTransport":"operation-file","inputPath":"input/source","outputPath":"output/result.md","deadlineMillisecondsSince1970":1\(strayKey)}
            """
            #expect(throws: ExtractorValidationError.self) {
                try JSONDecoder().decode(ExtractorProtocolRequest.self, from: Data(document.utf8))
            }
        }

        // A remote-url transport under an old revision: rejected.
        for revision in [1, 2] {
            let document = """
            {"requestID":"\(requestID)","protocolRevision":\(revision),"kind":"podcast-transcript","mimeType":"audio/podcast","originalFilename":"feed","inputTransport":"remote-url","remoteURL":"https://example.com/feed.rss","outputPath":"output/result.md","deadlineMillisecondsSince1970":1}
            """
            #expect(throws: ExtractorValidationError.self) {
                try JSONDecoder().decode(ExtractorProtocolRequest.self, from: Data(document.utf8))
            }
        }

        // A mixed shape (both transports) under revision 3: rejected.
        let mixed = """
        {"requestID":"\(requestID)","protocolRevision":3,"kind":"podcast-transcript","mimeType":"audio/podcast","originalFilename":"feed","inputTransport":"remote-url","inputPath":"input/source","remoteURL":"https://example.com/feed.rss","outputPath":"output/result.md","deadlineMillisecondsSince1970":1}
        """
        #expect(throws: ExtractorValidationError.self) {
            try JSONDecoder().decode(ExtractorProtocolRequest.self, from: Data(mixed.utf8))
        }
    }

    /// The typed constructors enforce the same revision rules as the decoder.
    @Test func constructorsRejectRemoteURLOldRevisions() throws {
        let url = try ExtractorRemoteSourceURL(validating: "https://example.com/feed.rss")
        for revision in [ExtractorProtocolRevision.v1, .v2] {
            #expect(throws: ExtractorValidationError.self) {
                try ExtractorProtocolRequest(
                    requestID: ExtractorRequestID(),
                    protocolRevision: revision,
                    kind: .podcastTranscript,
                    mimeType: mimeType(),
                    originalFilename: "feed",
                    remoteURL: url,
                    outputPath: outputPath(),
                    deadlineMillisecondsSince1970: 1)
            }
        }
        // v1 also rejects credential paths (existing rule); v3 keeps the
        // revision-2 credential/config envelope available.
        let v3WithCredential = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(),
            protocolRevision: .v3,
            kind: .podcastTranscript,
            mimeType: mimeType(),
            originalFilename: "feed",
            remoteURL: url,
            outputPath: outputPath(),
            deadlineMillisecondsSince1970: 1,
            credentialFilePath: ExtractorRelativePath(validating: "credentials/x/input.json"))
        #expect(v3WithCredential.credentialFilePath != nil)
        #expect(throws: ExtractorValidationError.self) {
            try ExtractorProtocolRequest(
                requestID: ExtractorRequestID(),
                protocolRevision: .v1,
                kind: .podcastTranscript,
                mimeType: mimeType(),
                originalFilename: "feed",
                inputPath: ExtractorRelativePath(validating: "input/source"),
                outputPath: outputPath(),
                deadlineMillisecondsSince1970: 1,
                credentialFilePath: ExtractorRelativePath(validating: "credentials/x/input.json"))
        }
    }

    /// Malformed source URL table: every rejected shape returns nil.
    @Test func malformedSourceURLsAreRejected() throws {
        let rejected: [String] = [
            "",
            "file:///etc/passwd",
            "data:text/plain,hello",
            "ftp://example.com/feed.rss",
            "https://user:secret@example.com/feed.rss",
            "https://user@example.com/feed.rss",
            "https://example.com/feed.rss#fragment",
            "https:///feed.rss",
            "https://",
            "example.com/feed.rss",
            "https://example.com/\u{0}",
            "https://example.com/" + String(repeating: "a", count: 2_049),
        ]
        for candidate in rejected {
            #expect(
                ExtractorRemoteSourceURL(rawValue: candidate) == nil,
                "expected rejection: \(candidate.prefix(48))")
        }
    }

    /// Valid URLs normalize: lowercase scheme and host, default port removed.
    @Test func validSourceURLsNormalize() throws {
        #expect(
            ExtractorRemoteSourceURL(rawValue: "HTTPS://EXAMPLE.com:443/feed.rss")?.rawValue
                == "https://example.com/feed.rss")
        #expect(
            ExtractorRemoteSourceURL(rawValue: "HTTP://EXAMPLE.com:80/feed")?.rawValue
                == "http://example.com/feed")
        #expect(
            ExtractorRemoteSourceURL(rawValue: "https://example.com:8443/feed")?.rawValue
                == "https://example.com:8443/feed")
        // Query strings survive; only fragments are rejected.
        #expect(
            ExtractorRemoteSourceURL(rawValue: "https://example.com/feed?i=1000123456789")?.rawValue
                == "https://example.com/feed?i=1000123456789")
        #expect(ExtractorRemoteSourceURL(rawValue: "https://192.168.1.1/feed.rss") != nil)
    }
}

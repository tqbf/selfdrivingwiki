import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// The manifest-claimed transcript cleanup (issue #1379): after a package
/// transcript lands as the raw head, the SAME extraction task runs a
/// best-effort agent cleanup when the package's registration declares the
/// claim, appending the cleaned copy as a new version parented to the raw
/// head. The agent is stubbed — never spawned (cooperative-pool rules).
@MainActor
@Suite("Transcript auto cleanup", .timeLimit(.minutes(2)))
struct TranscriptAutoCleanupTests {

    // MARK: - Fixtures

    private final class StubCleanupAgent: TranscriptCleanupAgent, @unchecked Sendable {
        let cleaned: String
        let error: Error?
        private(set) var callCount = 0
        private(set) var lastInput: String?

        init(cleaned: String) {
            self.cleaned = cleaned
            self.error = nil
        }

        init(error: Error) {
            self.cleaned = ""
            self.error = error
        }

        func clean(rawTranscript: String) async throws -> String {
            callCount += 1
            lastInput = rawTranscript
            if let error { throw error }
            return cleaned
        }
    }

    private struct CleanupFailed: Error {}

    /// Throws-unavailable extraction services: `persistTranscriptExtraction`
    /// never touches them — only the session box and the store.
    private struct UnavailableExtractionServices: ExtractionServices {
        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }
        func prepareHTML(backendOverride: HtmlExtractionBackend?) async throws -> any HtmlMarkdownExtractor {
            throw ExtractionServicesError.unavailable
        }
        func prepareDOCX() async throws -> any DocxMarkdownExtractor {
            throw ExtractionServicesError.unavailable
        }
        func preparePodcastTranscript() async throws -> ProcessPackagePodcastTranscript {
            throw ExtractionServicesError.unavailable
        }
        func prepareApplePodcastTranscript() async throws -> ProcessPackageApplePodcastTranscript {
            throw ExtractionServicesError.unavailable
        }
        func prepareYouTubeTranscript() async throws -> ProcessPackageYouTubeTranscript {
            throw ExtractionServicesError.unavailable
        }
        func prepareFetcher(sourceMIMEType: ExtractorMIMEType) async throws -> ProcessPackageFetcher {
            throw ExtractionServicesError.unavailable
        }
        func registeredExtractionInputs() async -> RegisteredExtractionInputs { .none }
        func activeRegistrationSnapshots() async -> [ExtractorRouteRegistrationSnapshot] { [] }
    }

    /// The reviewed YouTube package identity — the exact baseProducer the
    /// youtube route resolves in production.
    private static let youtubePackage = ReviewedExtractorPackages.youtubeTranscript

    private static func youtubeResolution() throws -> TranscriptExtractionResolution {
        let producer = ExtractionInstalledPackageProducer(
            revision: youtubePackage.revision,
            registrationID: try ExtractorRegistrationID(validating: "captions"),
            protocolRevision: .v3,
            reportedMetadata: try ExtractorReportedMetadata(toolName: "youtube-transcript"))
        return TranscriptExtractionResolution(
            fetch: { _ in
                TranscriptFetchOutcome(
                    markdown: "uh um RAW CAPTIONS",
                    reportedMetadata: try ExtractorReportedMetadata(toolName: "youtube-transcript"))
            },
            filename: "youtube-dQw4w9WgXcQ",
            resultMode: .installedPackage(producer))
    }

    private static func outcome() throws -> TranscriptFetchOutcome {
        TranscriptFetchOutcome(
            markdown: "uh um RAW CAPTIONS",
            reportedMetadata: try ExtractorReportedMetadata(toolName: "youtube-transcript"))
    }

    private func claims(wantsAgentCleanup: Bool) -> RegisteredExtractionInputs {
        RegisteredExtractionInputs(claims: [
            .init(
                kind: .youtubeTranscript,
                mimeTypes: ["video/youtube"],
                filenameExtensions: [],
                wantsAgentCleanup: wantsAgentCleanup),
        ])
    }

    /// Seeds one byteless YouTube source and returns (model, sourceID).
    private func makeSession(wantsAgentCleanup: Bool) throws -> (WikiStoreModel, SourceID) {
        let store = try TestStoreFactory.inMemory()
        let summary = try store.addBytelessSource(
            filename: "youtube-dQw4w9WgXcQ",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: SourceProvider.youtube.rawValue,
                activityKind: "fetch",
                plan: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                externalRef: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                externalIdentity: "dQw4w9WgXcQ"),
            role: .primary)
        let model = WikiStoreModel(store: store)
        model.registeredExtractionInputs = claims(wantsAgentCleanup: wantsAgentCleanup)
        return (model, summary.id)
    }

    private func makeProvider(
        model: WikiStoreModel,
        cleanupAgent: StubCleanupAgent?
    ) -> AppQueueExtractionProvider {
        let box = SessionLookupBox()
        box.setLookup { _ in model }
        return AppQueueExtractionProvider(
            extractionServices: UnavailableExtractionServices(),
            sessionBox: box,
            transcriptCleanupAgent: cleanupAgent)
    }

    // MARK: - Claimed cleanup

    @Test func claimedCleanupAppendsCleanedHeadParentedToRaw() async throws {
        let (model, sourceID) = try makeSession(wantsAgentCleanup: true)
        let agent = StubCleanupAgent(cleaned: "Cleaned captions.")
        let provider = makeProvider(model: model, cleanupAgent: agent)

        let reference = try await provider.persistTranscriptExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: try Self.youtubeResolution(), outcome: Self.outcome())

        // The agent ran exactly once, over the raw transcript.
        #expect(agent.callCount == 1)
        #expect(agent.lastInput == "uh um RAW CAPTIONS")

        let head = try #require(try model.internalStore.processedMarkdownHead(
            sourceID: sourceID))
        #expect(head.content == "Cleaned captions.")
        #expect(head.origin == .transcript)
        #expect(head.note == "auto transcript cleanup")
        #expect(head.technique == "transcript-cleanup")
        // The cleaned version is parented to the raw version — and the
        // extraction's output reference still points at that RAW version
        // (cleanup is best-effort on top of a completed extraction).
        let rawVersionID = try #require(head.parentID)
        #expect(rawVersionID.rawValue == reference?.versionID)
        #expect(try model.internalStore.processedMarkdownHistory(sourceID: sourceID)
            .contains(where: { $0.id == rawVersionID }))
        #expect(try model.internalStore.processedMarkdownHistory(sourceID: sourceID)
            .contains(where: { $0.content == "uh um RAW CAPTIONS" }))
    }

    // MARK: - No claim

    @Test func noClaimSkipsCleanup() async throws {
        let (model, sourceID) = try makeSession(wantsAgentCleanup: false)
        let agent = StubCleanupAgent(cleaned: "should never happen")
        let provider = makeProvider(model: model, cleanupAgent: agent)

        _ = try await provider.persistTranscriptExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: try Self.youtubeResolution(), outcome: Self.outcome())

        #expect(agent.callCount == 0)
        let head = try #require(try model.internalStore.processedMarkdownHead(
            sourceID: sourceID))
        #expect(head.content == "uh um RAW CAPTIONS")
    }

    // MARK: - Failure tolerance

    @Test func cleanupFailureKeepsRawCanonicalAndStillCompletes() async throws {
        let (model, sourceID) = try makeSession(wantsAgentCleanup: true)
        let agent = StubCleanupAgent(error: CleanupFailed())
        let provider = makeProvider(model: model, cleanupAgent: agent)

        // The extraction item still completes: persist returns the RAW
        // version reference and never throws.
        let reference = try await provider.persistTranscriptExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: try Self.youtubeResolution(), outcome: Self.outcome())

        #expect(agent.callCount == 1)
        let head = try #require(try model.internalStore.processedMarkdownHead(
            sourceID: sourceID))
        #expect(head.content == "uh um RAW CAPTIONS")
        #expect(head.id.rawValue == reference?.versionID)
        // No cleaned version was appended.
        #expect(try model.internalStore.processedMarkdownHistory(sourceID: sourceID).count == 1)
    }

    // MARK: - Empty transcript

    @Test func emptyRawTranscriptSkipsCleanup() async throws {
        let (model, sourceID) = try makeSession(wantsAgentCleanup: true)
        let agent = StubCleanupAgent(cleaned: "should never happen")
        let provider = makeProvider(model: model, cleanupAgent: agent)

        _ = try await provider.persistTranscriptExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: try Self.youtubeResolution(),
            outcome: TranscriptFetchOutcome(
                markdown: "   ",
                reportedMetadata: try ExtractorReportedMetadata(toolName: "youtube-transcript")))

        #expect(agent.callCount == 0)
    }
}

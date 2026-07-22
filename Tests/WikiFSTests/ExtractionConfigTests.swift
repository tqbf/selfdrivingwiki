import Foundation
import Testing
@testable import WikiFSCore

/// `ExtractionConfig` load/save round-trip, defaulting, and resilient decode
/// — mirrors `ZoteroConfigTests`'s temp-directory pattern.
struct ExtractionConfigTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extraction-config-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func defaultsAreLocalPdf2mdAndSonnetModel() {
        let config = ExtractionConfig()
        #expect(config.backend == .localPdf2md)
        #expect(config.anthropicModel == ExtractionConfig.defaultAnthropicModel)
        #expect(config.anthropicBaseURLOverride == nil)
        #expect(config.geminiModel == ExtractionConfig.defaultGeminiModel)
        #expect(config.geminiBaseURLOverride == nil)
        #expect(config.doclingServeEndpoint == nil)
    }

    @Test func savesAndLoadsRoundTrip() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.backend = .gemini
        config.anthropicModel = "claude-sonnet-4-6"
        config.anthropicBaseURLOverride = "https://proxy.example.com"
        config.geminiModel = "gemini-3.1-flash-lite"
        config.geminiBaseURLOverride = "https://vertex.example.com"
        config.doclingServeEndpoint = "http://localhost:5001"
        try config.save(to: dir)

        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == config)
    }

    @Test func missingFileLoadsDefaults() {
        let config = ExtractionConfig.load(from: tempDirectory())
        #expect(config == ExtractionConfig())
    }

    @Test func corruptFileLoadsDefaults() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent(ExtractionConfig.fileName, isDirectory: false)
        try Data("not json".utf8).write(to: url)
        #expect(ExtractionConfig.load(from: dir) == ExtractionConfig())
    }

    @Test func partialJSONFillsMissingFieldsWithDefaults() throws {
        // A file written by an older version that only knew `backend` should
        // still load, with the newer fields defaulting rather than throwing.
        let json = Data(#"{"backend":"anthropic"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.anthropicModel == ExtractionConfig.defaultAnthropicModel)
        #expect(config.anthropicBaseURLOverride == nil)
        #expect(config.geminiModel == ExtractionConfig.defaultGeminiModel)
        #expect(config.geminiBaseURLOverride == nil)
        #expect(config.doclingServeEndpoint == nil)
    }

    @Test func unknownBackendValueDegradesToLocalPdf2md() throws {
        // A future/typo'd backend raw value shouldn't crash the decode; it falls
        // back to the safe local default (mirrors `load`'s corrupt-file rule).
        let json = Data(#"{"backend":"totally_made_up"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .localPdf2md)
    }

    @Test func nilFieldsRoundTripAsNil() throws {
        let dir = tempDirectory()
        let config = ExtractionConfig(
            backend: .doclingServe,
            anthropicModel: "claude-opus-4-8",
            anthropicBaseURLOverride: nil,
            doclingServeEndpoint: nil)
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == config)
        #expect(loaded.anthropicBaseURLOverride == nil)
        #expect(loaded.doclingServeEndpoint == nil)
    }

    @Test func backendDisplayNameAndHelpTextForAllCases() {
        for backend in ExtractionBackend.allCases {
            #expect(!backend.displayName.isEmpty)
            #expect(!backend.helpText.isEmpty)
        }
        #expect(ExtractionBackend.localPdf2md.displayName == "Local pdf2md")
        #expect(ExtractionBackend.acp.displayName == "ACP Provider")
        #expect(ExtractionBackend.anthropic.displayName == "Claude (Anthropic API)")
        #expect(ExtractionBackend.gemini.displayName == "Gemini (Google AI)")
        #expect(ExtractionBackend.doclingServe.displayName == "Docling Serve")
    }

    @Test func acpBackendRoundTripsAgentName() {
        #expect(ExtractionBackend.acp.agentName == "acp-extraction")
        #expect(ExtractionBackend.from(agentName: "acp-extraction") == .acp)
    }

    @Test func acpProviderIdRoundTrips() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.backend = .acp
        config.acpProviderId = "claude-acp"
        try config.save(to: dir)

        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded.backend == .acp)
        #expect(loaded.acpProviderId == "claude-acp")
    }

    @Test func acpProviderIdDecodesAsNilWhenAbsent() throws {
        // A file written before the .acp backend existed (no acpProviderId key)
        // decodes with nil — forward-compatible.
        let json = Data(#"{"backend":"anthropic"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.acpProviderId == nil)
    }

    @Test func acpProviderIdRoundTripsNil() throws {
        let dir = tempDirectory()
        let config = ExtractionConfig(backend: .acp, acpProviderId: nil)
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded.acpProviderId == nil)
    }

    // MARK: - Issue #799 PR1: HTML + Podcast backend round-trip

    /// AC.1: `ExtractionConfig` round-trips all three backend fields
    /// (PDF + HTML + Podcast) via save/load.
    @Test func htmlAndPodcastBackendsRoundTrip() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.backend = .doclingServe
        config.htmlBackend = .tagBased
        config.podcastBackend = .appleTranscript
        try config.save(to: dir)

        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == config)
        #expect(loaded.backend == .doclingServe)
        #expect(loaded.htmlBackend == .tagBased)
        #expect(loaded.podcastBackend == .appleTranscript)
    }

    /// AC.1 (negative case): both new fields round-trip nil when explicitly
    /// reset — the "prompt me" state must survive a save/load.
    @Test func htmlAndPodcastBackendsRoundTripNil() throws {
        let dir = tempDirectory()
        let config = ExtractionConfig(
            backend: .anthropic,
            htmlBackend: nil,
            podcastBackend: nil)
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded == config)
        #expect(loaded.htmlBackend == nil)
        #expect(loaded.podcastBackend == nil)
    }

    /// AC.2: a legacy config file written before issue #799 PR1 shipped (no
    /// `htmlBackend` / `podcastBackend` keys) decodes both new fields as nil
    /// — the user is prompted to pick a backend on first extraction.
    /// Mirrors `acpProviderIdDecodesAsNilWhenAbsent` forward-compat contract.
    @Test func htmlAndPodcastBackendsDecodeAsNilWhenAbsent() throws {
        let json = Data(#"{"backend":"anthropic"}"#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.htmlBackend == nil)
        #expect(config.podcastBackend == nil)
    }

    /// Unknown raw values for the new backends degrade silently to nil —
    /// symmetric with `unknownBackendValueDegradesToLocalPdf2md` for the PDF
    /// `backend` field (a future/typo'd raw value doesn't crash the decode,
    /// the whole config still loads, the optional field just ends up nil). A
    /// typo'd `htmlBackend` therefore picks "prompt me" rather than rejecting
    /// the entire config — same resilient-decode philosophy as the existing
    /// fields, and the safer posture for a fresh-install user who hand-edited
    /// the JSON.
    @Test func unknownHtmlAndPodcastBackendValuesDegradeToNil() throws {
        let json = Data(#"""
        {"backend":"anthropic","htmlBackend":"whisper","podcastBackend":"rev_ai"}
        """#.utf8)
        let config = try JSONDecoder().decode(ExtractionConfig.self, from: json)
        #expect(config.backend == .anthropic)
        #expect(config.htmlBackend == nil)
        #expect(config.podcastBackend == nil)
    }

    /// A config with the new backends also persists the existing PDF backend
    /// unchanged — the three fields coexist in one file without crosstalk.
    @Test func pdfBackendSurvivesWhenNewBackendsAreSet() throws {
        let dir = tempDirectory()
        var config = ExtractionConfig()
        config.backend = .acp
        config.acpProviderId = "claude-acp"
        config.htmlBackend = .defuddle
        config.podcastBackend = .appleTranscript
        try config.save(to: dir)
        let loaded = ExtractionConfig.load(from: dir)
        #expect(loaded.backend == .acp)
        #expect(loaded.acpProviderId == "claude-acp")
        #expect(loaded.htmlBackend == .defuddle)
        #expect(loaded.podcastBackend == .appleTranscript)
    }
}

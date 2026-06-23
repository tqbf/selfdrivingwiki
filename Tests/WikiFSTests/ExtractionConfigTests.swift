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
        #expect(ExtractionBackend.anthropic.displayName == "Claude (Anthropic API)")
        #expect(ExtractionBackend.gemini.displayName == "Gemini (Google AI)")
        #expect(ExtractionBackend.doclingServe.displayName == "Docling Serve")
    }
}

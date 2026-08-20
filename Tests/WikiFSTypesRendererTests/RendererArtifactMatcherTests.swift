import Foundation
import Testing
import WikiFSTypes

struct RendererArtifactMatcherTests {
    @Test func identifiesBoundedExcalidrawArtifact() {
        #expect(RendererJSONArtifact.excalidraw.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.excalidraw))
        #expect(RendererJSONArtifact.jsonCanvas.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.excalidraw) == false)
    }

    @Test func identifiesBoundedJSONCanvasArtifact() {
        #expect(RendererJSONArtifact.jsonCanvas.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.jsonCanvas))
        #expect(RendererJSONArtifact.excalidraw.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.jsonCanvas) == false)
    }

    @Test func rejectsValidJSONCanvasWhenPrefixIsTruncated() throws {
        let input = try RendererMatchInput(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: "canvas"),
            sniffedBytes: Phase6RendererArtifactFixtures.jsonCanvas,
            sniffedBytesAreComplete: false,
            artifactKind: .source)
        #expect(RendererMatcher.boundedJSONArtifact(.jsonCanvas).matches(input) == false)
    }

    @Test func rejectsMalformedArtifactsAndOversizedSniffs() throws {
        #expect(RendererJSONArtifact.excalidraw.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.malformedExcalidraw) == false)
        #expect(RendererJSONArtifact.jsonCanvas.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.malformedJSONCanvas) == false)
        #expect(RendererJSONArtifact.excalidraw.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.malformedJSON) == false)

        let oversized = Data(repeating: 0, count: RendererMatchingLimits.maximumSniffByteCount + 1)
        #expect(RendererJSONArtifact.excalidraw.matches(sniffedBytes: oversized) == false)
        #expect(throws: RendererValidationError.invalidSizeLimit("sniff byte count \(oversized.count)")) {
            _ = try RendererMatchInput(
                mimeType: nil,
                fileExtension: nil,
                sniffedBytes: oversized,
                artifactKind: .source)
        }
    }
}

struct RendererArtifactRegistryTests {
    @Test func registrySelectsOnlyTheTypedArtifactIndependentlyOfInputOrder() throws {
        let excalidraw = try Phase6RendererArtifactFixtures.descriptor(
            packageID: "org.example.excalidraw",
            registrationID: "excalidraw",
            fileExtension: "excalidraw",
            artifact: .excalidraw)
        let canvas = try Phase6RendererArtifactFixtures.descriptor(
            packageID: "org.example.canvas",
            registrationID: "json-canvas",
            fileExtension: "canvas",
            artifact: .jsonCanvas)
        let forward = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [excalidraw, canvas])
        let reverse = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [canvas, excalidraw])

        let excalidrawInput = try Phase6RendererArtifactFixtures.input(
            bytes: Phase6RendererArtifactFixtures.excalidraw,
            fileExtension: "excalidraw")
        let canvasInput = try Phase6RendererArtifactFixtures.input(
            bytes: Phase6RendererArtifactFixtures.jsonCanvas,
            fileExtension: "canvas")

        #expect(forward.matching(excalidrawInput).map(\.reference) == [excalidraw.reference])
        #expect(reverse.matching(excalidrawInput).map(\.reference) == [excalidraw.reference])
        #expect(forward.matching(canvasInput).map(\.reference) == [canvas.reference])
        #expect(reverse.matching(canvasInput).map(\.reference) == [canvas.reference])
    }

    @Test func malformedArtifactKeepsRegistryEmptyForHostSourceFallback() throws {
        let excalidraw = try Phase6RendererArtifactFixtures.descriptor(
            packageID: "org.example.excalidraw",
            registrationID: "excalidraw",
            fileExtension: "excalidraw",
            artifact: .excalidraw)
        let canvas = try Phase6RendererArtifactFixtures.descriptor(
            packageID: "org.example.canvas",
            registrationID: "json-canvas",
            fileExtension: "canvas",
            artifact: .jsonCanvas)
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [excalidraw, canvas])
        let malformedExcalidraw = try Phase6RendererArtifactFixtures.input(
            bytes: Phase6RendererArtifactFixtures.malformedExcalidraw,
            fileExtension: "excalidraw")
        let malformedCanvas = try Phase6RendererArtifactFixtures.input(
            bytes: Phase6RendererArtifactFixtures.malformedJSONCanvas,
            fileExtension: "canvas")

        #expect(snapshot.matching(malformedExcalidraw).isEmpty)
        #expect(snapshot.matching(malformedCanvas).isEmpty)
        #expect(snapshot.preferred(
            preference: .exact(excalidraw.reference),
            input: malformedExcalidraw) == nil)
    }
}

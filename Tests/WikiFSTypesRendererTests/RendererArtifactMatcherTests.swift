import Foundation
import Testing
import WikiFSTypes

struct RendererArtifactMatcherTests {
    @Test func identifiesBoundedExcalidrawConstraints() throws {
        let constraints = try Phase6RendererArtifactFixtures.excalidrawConstraints()
        #expect(constraints.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.excalidraw,
            isComplete: true))
        #expect(!constraints.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.jsonCanvas,
            isComplete: true))
    }

    @Test func identifiesBoundedJSONCanvasConstraints() throws {
        let constraints = try Phase6RendererArtifactFixtures.jsonCanvasConstraints()
        #expect(constraints.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.jsonCanvas,
            isComplete: true))
        #expect(!constraints.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.excalidraw,
            isComplete: true))
    }

    @Test func rejectsValidJSONCanvasWhenPrefixIsTruncated() throws {
        let input = try RendererMatchInput(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: "canvas"),
            sniffedBytes: Phase6RendererArtifactFixtures.jsonCanvas,
            sniffedBytesAreComplete: false,
            artifactKind: .source)
        #expect(!RendererMatcher.boundedJSON(try Phase6RendererArtifactFixtures.jsonCanvasConstraints()).matches(input))
    }

    @Test func rejectsMalformedArtifactsAndOversizedSniffs() throws {
        let excalidraw = try Phase6RendererArtifactFixtures.excalidrawConstraints()
        let canvas = try Phase6RendererArtifactFixtures.jsonCanvasConstraints()
        #expect(!excalidraw.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.malformedExcalidraw,
            isComplete: true))
        #expect(!canvas.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.malformedJSONCanvas,
            isComplete: true))
        #expect(!excalidraw.matches(
            sniffedBytes: Phase6RendererArtifactFixtures.malformedJSON,
            isComplete: true))
        #expect(!excalidraw.matches(
            sniffedBytes: Data(#"{"type":"excalidraw","version":true,"elements":[]}"#.utf8),
            isComplete: true))

        let oversized = Data(repeating: 0, count: RendererMatchingLimits.maximumSniffByteCount + 1)
        #expect(!excalidraw.matches(sniffedBytes: oversized, isComplete: true))
        #expect(throws: RendererValidationError.invalidSizeLimit("sniff byte count \(oversized.count)")) {
            _ = try RendererMatchInput(
                mimeType: nil,
                fileExtension: nil,
                sniffedBytes: oversized,
                artifactKind: .source)
        }
    }
}

struct RendererLegacyMatcherCompatibilityTests {
    @Test("legacy 1.0.4 matcher decodes to generic constraints and preserves its wire token")
    func legacyMatcherRoundTripsWithoutChangingRuntimeMatching() throws {
        let legacy = Data(#"{"boundedJSONArtifact":{"_0":"excalidraw"}}"#.utf8)
        let matcher = try JSONDecoder().decode(RendererMatcher.self, from: legacy)
        let validInput = try RendererMatchInput(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: "excalidraw"),
            sniffedBytes: Phase6RendererArtifactFixtures.excalidraw,
            artifactKind: .source)
        let invalidInput = try RendererMatchInput(
            mimeType: try .init(validating: "application/json"),
            fileExtension: try .init(validating: "excalidraw"),
            sniffedBytes: Phase6RendererArtifactFixtures.malformedExcalidraw,
            artifactKind: .source)

        #expect(matcher.matches(validInput))
        #expect(!matcher.matches(invalidInput))
        #expect(matcher.requiresArtifactValidation)
        #expect(try JSONEncoder().encode(matcher) == legacy)
    }

    @Test("new JSON matcher encodes only the generic wire shape")
    func newMatcherUsesGenericWireShape() throws {
        let constraints = try Phase6RendererArtifactFixtures.excalidrawConstraints()
        let matcher = RendererMatcher.boundedJSON(constraints)
        let encoded = try JSONEncoder().encode(matcher)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(json.contains("boundedJSON"))
        #expect(!json.contains("boundedJSONArtifact"))
    }
}

struct RendererArtifactRegistryTests {
    @Test func registrySelectsOnlyTheTypedArtifactIndependentlyOfInputOrder() throws {
        let excalidraw = try Phase6RendererArtifactFixtures.descriptor(
            packageID: "org.example.excalidraw",
            registrationID: "excalidraw",
            fileExtension: "excalidraw",
            constraints: try Phase6RendererArtifactFixtures.excalidrawConstraints())
        let canvas = try Phase6RendererArtifactFixtures.descriptor(
            packageID: "org.example.canvas",
            registrationID: "json-canvas",
            fileExtension: "canvas",
            constraints: try Phase6RendererArtifactFixtures.jsonCanvasConstraints())
        let forward = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [excalidraw, canvas])
        let reverse = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [canvas, excalidraw])

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
            constraints: try Phase6RendererArtifactFixtures.excalidrawConstraints())
        let canvas = try Phase6RendererArtifactFixtures.descriptor(
            packageID: "org.example.canvas",
            registrationID: "json-canvas",
            fileExtension: "canvas",
            constraints: try Phase6RendererArtifactFixtures.jsonCanvasConstraints())
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [excalidraw, canvas])
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

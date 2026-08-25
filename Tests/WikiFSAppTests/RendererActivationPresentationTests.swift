#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

/// `WindowGroup(for:)` keys a renderer window by this value, so its
/// hand-written `Equatable`/`Hashable` decides whether activating a renderer
/// focuses the open window or stacks another one.
@Suite("Renderer activation window key")
struct RendererActivationPresentationTests {
    @Test("the same content in the same wiki is one window")
    func identicalContentSharesAWindow() throws {
        let first = try Self.presentation()
        let second = try Self.presentation()

        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        #expect(Set([first, second]).count == 1)
    }

    @Test("source activation reads exact pinned bytes for the renderer window")
    @MainActor
    func sourceActivationReadsExactPinnedBytes() throws {
        let store = try GRDBWikiStore(databaseURL: temporaryDatabaseURL())
        let bytes = Data(#"{"type":"excalidraw","version":2,"elements":[]}"#.utf8)
        let source = try store.addSource(
            filename: "architecture.json",
            data: bytes,
            mimeType: "application/json")
        let activeVersion = try store.activeContentVersion(sourceID: source.id)
        let version = try #require(activeVersion)
        let payload = try RendererActivationView.authorizedPayload(
            store: store,
            input: .source(versionID: version.id))

        #expect(payload.mimeType == "application/json")
        #expect(payload.bytes == bytes)
    }

    @Test("different content or a different wiki is a different window")
    func differingContentOrWikiSeparatesWindows() throws {
        let base = try Self.presentation()

        #expect(try base != Self.presentation(bytes: Self.otherBytes))
        #expect(try base != Self.presentation(wikiID: WikiID(rawValue: "01JWIKI0000000000000000002")))
        #expect(try base != Self.presentation(registrationID: "json-canvas"))
        #expect(try Set([base, Self.presentation(bytes: Self.otherBytes)]).count == 2)
    }

    // MARK: Fixtures

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-activation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    private static let bytes = Data(#"{"type":"excalidraw","version":2,"elements":[]}"#.utf8)
    private static let otherBytes = Data(#"{"type":"excalidraw","version":2,"elements":[],"files":{}}"#.utf8)

    private static func presentation(
        bytes: Data = bytes,
        wikiID: WikiID = WikiID(rawValue: "01JWIKI0000000000000000001"),
        registrationID: String = "excalidraw"
    ) throws -> RendererActivationPresentation {
        let identity = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01JWINDOWPAGE0000000000001"),
            pageVersionID: PageVersionID(rawValue: "01JWINDOWVERSION000000001"))
        let block = try MarkdownFencedBlock(
            documentIdentity: identity,
            parserOrdinal: 0,
            rawInfoString: "excalidraw",
            bytes: bytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: identity.pageID,
            pageVersionID: identity.pageVersionID,
            blockID: try #require(block.blockID),
            fenceKind: .excalidraw,
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
        return RendererActivationPresentation(
            reference: RendererReference(
                packageID: try #require(RendererPackageID(rawValue: "org.selfdrivingwiki.excalidraw-readonly")),
                version: try #require(RendererPackageVersion(rawValue: "1.0.1")),
                registrationID: try #require(RendererRegistrationID(rawValue: registrationID))),
            input: .inlineArtifact(artifact),
            wikiID: wikiID)
    }
}
#endif

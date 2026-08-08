#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

@MainActor
struct RendererContentWorldBridgeTests {
    @Test("isolated-world bridge replies only to bound main-frame package messages")
    func repliesWithPinnedPayloadAfterProvenanceChecks() throws {
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "input.txt", data: Data("ok".utf8))
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let input = RendererBridgeInput.source(versionID: version.id)
        let pageRequest = RendererBridgePageRequest(
            id: .init(rawValue: "request-1"), method: .inputRead, input: input
        )
        let reader = RendererAuthorizedInputReader(store: store, authorizedInput: input)
        let broker = RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()), capability: .init(rawValue: "secret"), inputReader: reader
        )
        let webView = NSObject()
        broker.bind(webViewID: ObjectIdentifier(webView))
        let handler = RendererScriptMessageHandler(
            broker: broker, expectedContentWorld: .page, sessionIsReady: { true }
        )
        let message = RendererBridgeScriptMessage(
            body: String(data: try JSONEncoder().encode(pageRequest), encoding: .utf8)!,
            isExpectedContentWorld: true,
            provenance: .init(
                webViewID: ObjectIdentifier(webView), originScheme: "renderer-package", originHost: "package", isMainFrame: true
            )
        )

        let (reply, error) = handler.response(for: message)

        #expect(error == nil)
        guard let replyText = reply as? String else {
            Issue.record("expected a bridge reply string")
            return
        }
        let decoded = try JSONDecoder().decode(RendererBridgeResponse.self, from: Data(replyText.utf8))
        #expect(decoded.id == pageRequest.id)
        #expect(decoded.payload == RendererBridgeInputPayload(mimeType: "text/plain", bytes: Data("ok".utf8)))
    }

    @Test("bridge shell rejects wrong world and page provenance")
    func rejectsWrongWorldAndProvenance() throws {
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "input.md", data: Data())
        let markdown = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "", origin: .user, note: nil
        )
        let input = RendererBridgeInput.markdown(versionID: markdown.id)
        let reader = RendererAuthorizedInputReader(store: store, authorizedInput: input)
        let broker = RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()), capability: .init(rawValue: "secret"), inputReader: reader
        )
        let expectedWebView = NSObject()
        broker.bind(webViewID: ObjectIdentifier(expectedWebView))
        let handler = RendererScriptMessageHandler(
            broker: broker, expectedContentWorld: .page, sessionIsReady: { true }
        )
        let pageRequest = RendererBridgePageRequest(id: .init(rawValue: "request-2"), method: .inputRead, input: input)
        let body = String(data: try JSONEncoder().encode(pageRequest), encoding: .utf8)!
        let wrongWorld = RendererBridgeScriptMessage(
            body: body, isExpectedContentWorld: false,
            provenance: .init(webViewID: ObjectIdentifier(expectedWebView), originScheme: "renderer-package", originHost: "package", isMainFrame: true)
        )
        let wrongOrigin = RendererBridgeScriptMessage(
            body: body, isExpectedContentWorld: true,
            provenance: .init(webViewID: ObjectIdentifier(expectedWebView), originScheme: "https", originHost: "package", isMainFrame: true)
        )

        #expect(handler.response(for: wrongWorld).1 == "wrong content world")
        #expect(handler.response(for: wrongOrigin).1 == "request denied")
    }

    @Test("bridge rejects nil WebView provenance when no WebView is bound")
    func rejectsNilWebViewProvenanceWithoutBinding() throws {
        let (handler, message) = try makeHandlerAndMessage(binding: nil, observedWebViewID: nil)

        #expect(handler.response(for: message).1 == "request denied")
    }

    @Test("bridge rejects nil WebView provenance after binding")
    func rejectsNilWebViewProvenanceAfterBinding() throws {
        let webView = NSObject()
        let (handler, message) = try makeHandlerAndMessage(
            binding: ObjectIdentifier(webView), observedWebViewID: nil
        )

        #expect(handler.response(for: message).1 == "request denied")
    }

    private func makeHandlerAndMessage(
        binding: ObjectIdentifier?,
        observedWebViewID: ObjectIdentifier?
    ) throws -> (RendererScriptMessageHandler, RendererBridgeScriptMessage) {
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "input.txt", data: Data("ok".utf8))
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let input = RendererBridgeInput.source(versionID: version.id)
        let broker = RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()), capability: .init(rawValue: "secret"),
            inputReader: .init(store: store, authorizedInput: input)
        )
        if let binding { broker.bind(webViewID: binding) }
        let handler = RendererScriptMessageHandler(
            broker: broker, expectedContentWorld: .page, sessionIsReady: { true }
        )
        let request = RendererBridgePageRequest(
            id: .init(rawValue: "request-nil-webview"), method: .inputRead, input: input
        )
        let body = try String(decoding: JSONEncoder().encode(request), as: UTF8.self)
        return (handler, .init(
            body: body, isExpectedContentWorld: true,
            provenance: .init(
                webViewID: observedWebViewID, originScheme: "renderer-package",
                originHost: "package", isMainFrame: true
            )
        ))
    }
}
#endif

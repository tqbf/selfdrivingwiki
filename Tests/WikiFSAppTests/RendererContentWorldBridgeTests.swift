#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

@MainActor
struct RendererContentWorldBridgeTests {
    @Test("input bootstrap exposes the pinned selector without a session capability")
    func inputBootstrapScriptExposesPinnedSelectorOnly() {
        let input = RendererBridgeInput.source(versionID: .init(rawValue: "source-version"))

        let source = RendererContentWorldBroker
            .inputBootstrapScript(input: input, contentWorld: .page)
            .source

        #expect(source.contains("document.documentElement.dataset.rendererInput"))
        #expect(source.contains("source-version"))
        #expect(source.contains("capability") == false)
    }

    @Test("navigation activation derives request identity from the fresh nonce")
    func navigationActivationUsesNonceDerivedRequestIdentity() {
        let source = RendererContentWorldBroker
            .navigationActivationScript(contentWorld: .page)
            .source

        #expect(source.contains("id: {rawValue: 'navigation-' + nonce}"))
        #expect(source.contains("requestSequence") == false)
    }

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

    @Test("host navigation routes only a declared activated target and returns a uniform acknowledgement")
    func hostNavigationRoutesActivatedTargetWithUniformAcknowledgement() throws {
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "input.txt", data: Data("ok".utf8))
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let input = RendererBridgeInput.source(versionID: version.id)
        let target = RendererNavigationTarget.page(PageID(rawValue: "01HXXXXXXXXXXXXXXXXXXXXXXX"))
        var routed: [RendererNavigationTarget] = []
        let broker = RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()),
            capability: .init(rawValue: "secret"),
            inputReader: .init(store: store, authorizedInput: input),
            allowedNavigationTargetKinds: [.page],
            routeNavigation: { routed.append($0) })
        let webView = NSObject()
        broker.bind(webViewID: ObjectIdentifier(webView))
        let nonce = try #require(broker.recordTrustedNavigationActivation(for: target))
        let envelope = RendererBridgePageEnvelope.navigation(.init(
            id: .init(rawValue: "navigation-1"),
            target: target,
            activationNonce: nonce))
        let handler = RendererScriptMessageHandler(
            broker: broker, expectedContentWorld: .page, sessionIsReady: { true })
        let message = RendererBridgeScriptMessage(
            body: try String(decoding: RendererBridgeEnvelope.encode(envelope), as: UTF8.self),
            isExpectedContentWorld: true,
            provenance: .init(
                webViewID: ObjectIdentifier(webView), originScheme: "renderer-package",
                originHost: "package", isMainFrame: true))

        let (reply, error) = handler.response(for: message)
        #expect(error == nil)
        let replyText = try #require(reply as? String)
        let acknowledgement = try JSONDecoder().decode(
            RendererNavigationAcknowledgement.self, from: Data(replyText.utf8))
        #expect(acknowledgement == .init(id: .init(rawValue: "navigation-1")))
        #expect(routed == [target])
        #expect(handler.response(for: message).1 == "request denied")
        #expect(routed == [target])
    }

    @Test("denied host navigation never invokes the router")
    func deniedHostNavigationNeverRoutes() throws {
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "input.txt", data: Data())
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let input = RendererBridgeInput.source(versionID: version.id)
        var routeCount = 0
        let broker = RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()), capability: .init(rawValue: "secret"),
            inputReader: .init(store: store, authorizedInput: input),
            allowedNavigationTargetKinds: [.page],
            routeNavigation: { _ in routeCount += 1 })
        let webView = NSObject()
        broker.bind(webViewID: ObjectIdentifier(webView))
        let undeclared = RendererNavigationTarget.source(SourceID(rawValue: "01HYYYYYYYYYYYYYYYYYYYYYYY"))
        let envelope = RendererBridgePageEnvelope.navigation(.init(
            id: .init(rawValue: "navigation-denied"), target: undeclared,
            activationNonce: .init(rawValue: "untrusted")))
        let handler = RendererScriptMessageHandler(
            broker: broker, expectedContentWorld: .page, sessionIsReady: { true })
        let message = RendererBridgeScriptMessage(
            body: try String(decoding: RendererBridgeEnvelope.encode(envelope), as: UTF8.self),
            isExpectedContentWorld: true,
            provenance: .init(
                webViewID: ObjectIdentifier(webView), originScheme: "renderer-package",
                originHost: "package", isMainFrame: true))

        #expect(handler.response(for: message).1 == "request denied")
        #expect(routeCount == 0)
        broker.close()
        #expect(handler.response(for: message).1 == "request denied")
        #expect(routeCount == 0)
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

    @Test("asset.read requires bound main-frame package provenance")
    func assetReadRequiresBoundMainFramePackageProvenance() throws {
        let (_, reference, handler, webViewID, _) = try makeAssetBrokerAndHandler()
        let request = RendererAssetPageRequest(
            id: .init(rawValue: "asset-1"), reference: reference)
        let body = try String(decoding: JSONEncoder().encode(RendererBridgePageEnvelope.asset(request)), as: UTF8.self)

        // Bound main-frame package provenance -> authorized asset read.
        let bound = handler.response(for: .init(
            body: body, isExpectedContentWorld: true,
            provenance: .init(webViewID: webViewID, originScheme: "renderer-package", originHost: "package", isMainFrame: true)))
        #expect(bound.1 == nil)
        if case let .some(text) = bound.0, let responseText = text as? String,
           let data = responseText.data(using: .utf8),
           let payload = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["payload"] as? [String: Any] {
            #expect(payload["mimeType"] as? String == "image/png")
            #expect(payload["bytes"] as? String == "iVBORw0KGgo=")
        } else {
            Issue.record("expected an asset response payload")
        }

        // Wrong provenance -> asset denied (uniform "request denied").
        let wrongOrigin = handler.response(for: .init(
            body: body, isExpectedContentWorld: true,
            provenance: .init(webViewID: webViewID, originScheme: "https", originHost: "evil.com", isMainFrame: true)))
        #expect(wrongOrigin.1 == "request denied")

        // Non-main frame -> denied.
        let subframe = handler.response(for: .init(
            body: body, isExpectedContentWorld: true,
            provenance: .init(webViewID: webViewID, originScheme: "renderer-package", originHost: "package", isMainFrame: false)))
        #expect(subframe.1 == "request denied")
    }

    @Test("asset.read stops after teardown without a store read")
    func assetReadStopsAfterTeardown() throws {
        let (_, reference, handler, webViewID, broker) = try makeAssetBrokerAndHandler()
        let request = RendererAssetPageRequest(
            id: .init(rawValue: "asset-1"), reference: reference)
        let body = try String(decoding: JSONEncoder().encode(RendererBridgePageEnvelope.asset(request)), as: UTF8.self)
        let provenance = RendererBridgeMessageProvenance(
            webViewID: webViewID, originScheme: "renderer-package", originHost: "package", isMainFrame: true)

        // Authorized before close.
        #expect(handler.response(for: .init(body: body, isExpectedContentWorld: true, provenance: provenance)).1 == nil)

        broker.close()
        // After teardown the asset read is denied uniformly (the asset
        // reader is closed and the broker session is closed).
        #expect(handler.response(for: .init(body: body, isExpectedContentWorld: true, provenance: provenance)).1 == "request denied")
    }

    @Test("asset denials are uniform and disclose no existence details")
    func assetDenialsAreUniform() throws {
        // A denied asset read must not disclose whether the reference exists.
        // No admitted assets -> every asset.read is denied with the same
        // uniform response and no body detail.
        let (_, _, handler, webViewID, _) = try makeAssetBrokerAndHandler(withAdmission: false)
        let request = RendererAssetPageRequest(
            id: .init(rawValue: "asset-any"), reference: try RendererAssetReference(validating: "whatever.png"))
        let body = try String(decoding: JSONEncoder().encode(RendererBridgePageEnvelope.asset(request)), as: UTF8.self)
        let provenance = RendererBridgeMessageProvenance(
            webViewID: webViewID, originScheme: "renderer-package", originHost: "package", isMainFrame: true)
        let response = handler.response(for: .init(body: body, isExpectedContentWorld: true, provenance: provenance))
        #expect(response.1 == "request denied")
        // Two denials look identical: same message, no body detail.
        let second = handler.response(for: .init(body: body, isExpectedContentWorld: true, provenance: provenance))
        #expect(second.1 == response.1)
        #expect(second.0 == nil && response.0 == nil)
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

    /// A store-backed broker with an admitted diagram.png asset reader.
    private func makeAssetBrokerAndHandler(
        withAdmission: Bool = true
    ) throws -> (store: GRDBWikiStore, assetReference: RendererAssetReference, handler: RendererScriptMessageHandler, webViewID: ObjectIdentifier, broker: RendererContentWorldBroker) {
        let store = try GRDBWikiStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let summary = try store.addSource(filename: "diagram.png", data: png)
        let version = try #require(try store.activeContentVersion(sourceID: summary.id))
        let reference = try RendererAssetReference(validating: "diagram.png")
        let admission = RendererAuthorizedAssetReader.Admission(
            reference: reference,
            sourceID: summary.id,
            sourceVersionID: version.id,
            mimeType: "image/png",
            expectedByteCount: png.count,
            expectedDigest: RendererSHA256.digest(png).hex)
        let assetReader = withAdmission ? try RendererAuthorizedAssetReader(
            admissions: [admission],
            maximumBytesPerAsset: 4096,
            maximumAggregateSessionBytes: 8192,
            maximumPerRequestReadCount: 4,
            store: store) : nil
        let pageID = PageID(rawValue: "01HXXXXXXXXXXXXXXXXXXXXXXX")
        let pageVersionID = PageVersionID(rawValue: "01HXXXXXXXXXXXXXXXXXXXXXXX")
        let document = MarkdownDocumentIdentity(pageID: pageID, pageVersionID: pageVersionID)
        let block = try MarkdownFencedBlock(
            documentIdentity: document,
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: Data("{\"nodes\":[]}".utf8))
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: try RendererFenceAlias(validating: "jsoncanvas"),
            mimeType: try RendererMIMEType(validating: "application/json"),
            bytes: Data("{\"nodes\":[]}".utf8))
        let broker = RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()), capability: .init(rawValue: "secret"),
            inputReader: .init(store: store, authorizedInput: .inlineArtifact(artifact)),
            assetReader: assetReader)
        let webView = NSObject()
        let webViewID = ObjectIdentifier(webView)
        broker.bind(webViewID: webViewID)
        let handler = RendererScriptMessageHandler(
            broker: broker, expectedContentWorld: .page, sessionIsReady: { true }
        )
        return (store, reference, handler, webViewID, broker)
    }
}
#endif

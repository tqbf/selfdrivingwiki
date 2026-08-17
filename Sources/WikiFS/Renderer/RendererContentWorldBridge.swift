#if os(macOS)
import Foundation
import WebKit
import WikiFSCore

// pattern: Imperative Shell

/// Testable form of the WebKit metadata that establishes page provenance.
@MainActor
struct RendererBridgeMessageProvenance {
    let webViewID: ObjectIdentifier?
    let originScheme: String
    let originHost: String
    let isMainFrame: Bool
}

/// Testable form of a WebKit script message after the adapter has extracted
/// its body, content-world result, and provenance.
@MainActor
struct RendererBridgeScriptMessage {
    let body: Any
    let isExpectedContentWorld: Bool
    let provenance: RendererBridgeMessageProvenance
}

/// Main-actor adapter between the page's narrow postMessage envelope and the
/// session-bound core bridge. The page never sees this handler's native name or
/// the capability it adds before authorization.
@MainActor
final class RendererContentWorldBroker {
    private var authorizer: RendererBridgeAuthorizer
    private let inputReader: RendererAuthorizedInputReader
    private let sessionID: RendererSessionID
    private let windowID: UUID
    private let capability: RendererSessionCapability
    private let mainFrameID = UUID()
    private var isClosed = false
    private var expectedWebViewID: ObjectIdentifier?
    private let expectedOrigin: (scheme: String, host: String)

    init(
        sessionID: RendererSessionID,
        capability: RendererSessionCapability,
        inputReader: RendererAuthorizedInputReader,
        expectedOrigin: URL = URL(string: "renderer-package://package")!
    ) {
        self.sessionID = sessionID
        windowID = UUID()
        self.capability = capability
        self.inputReader = inputReader
        self.expectedOrigin = (expectedOrigin.scheme ?? "", expectedOrigin.host ?? "")
        authorizer = RendererBridgeAuthorizer(
            capability: capability,
            sessionID: sessionID,
            windowID: windowID,
            authorizedInput: inputReader.authorizedInput
        )
    }

    func bind(to webView: WKWebView) { expectedWebViewID = ObjectIdentifier(webView) }

    func bind(webViewID: ObjectIdentifier) { expectedWebViewID = webViewID }

    var pageInput: RendererBridgeInput { inputReader.authorizedInput }

    func handlePageEnvelope(
        _ envelope: Data,
        provenance: RendererBridgeMessageProvenance,
        sessionIsReady: Bool
    ) throws -> Data {
        guard let expectedWebViewID,
              let observedWebViewID = provenance.webViewID,
              observedWebViewID == expectedWebViewID
        else {
            throw RendererBridgeAuthorizationError.wrongWindow
        }
        guard provenance.originScheme == expectedOrigin.scheme,
              provenance.originHost == expectedOrigin.host
        else { throw RendererBridgeAuthorizationError.wrongWindow }
        guard provenance.isMainFrame else { throw RendererBridgeAuthorizationError.nonMainFrame }
        guard envelope.count <= WikiAppWebViewPolicy.maximumBridgeMessageByteCount else {
            throw RendererBridgeAuthorizationError.oversizedEnvelope
        }
        let pageRequest: RendererBridgePageRequest
        do {
            pageRequest = try RendererBridgeEnvelope.decodePageRequest(from: envelope)
        } catch {
            throw RendererBridgeAuthorizationError.malformedEnvelope
        }
        let request = RendererBridgeRequest(
            id: pageRequest.id,
            method: pageRequest.method,
            capability: capability,
            input: pageRequest.input
        )
        let context = RendererBridgeAuthorizationContext(
            sessionID: sessionID,
            windowID: windowID,
            frameID: mainFrameID,
            mainFrameID: mainFrameID
        )
        _ = try authorizer.authorize(
            envelope: RendererBridgeEnvelope.encode(request),
            context: context,
            sessionIsReady: sessionIsReady,
            sessionIsClosed: isClosed
        )
        let payload = try inputReader.read(request.input)
        let response = try RendererBridgeEnvelope.encode(.init(id: request.id, payload: payload))
        guard response.count <= WikiAppWebViewPolicy.maximumBridgeMessageByteCount else {
            throw RendererBridgeAuthorizationError.oversizedPayload
        }
        return response
    }

    func close() {
        isClosed = true
        inputReader.close()
    }
}

/// Receives only messages registered in the session's isolated content world.
/// A separate user script relays page `postMessage` values into this handler.
@MainActor
final class RendererScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let broker: RendererContentWorldBroker
    private let sessionIsReady: () -> Bool
    private let expectedContentWorld: WKContentWorld

    init(
        broker: RendererContentWorldBroker,
        expectedContentWorld: WKContentWorld,
        sessionIsReady: @escaping () -> Bool
    ) {
        self.broker = broker
        self.expectedContentWorld = expectedContentWorld
        self.sessionIsReady = sessionIsReady
    }

    @available(macOS 11.0, *)
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        response(for: .init(
            body: message.body,
            isExpectedContentWorld: message.world === expectedContentWorld,
            provenance: .init(
                webViewID: message.webView.map(ObjectIdentifier.init),
                originScheme: message.frameInfo.securityOrigin.protocol,
                originHost: message.frameInfo.securityOrigin.host,
                isMainFrame: message.frameInfo.isMainFrame
            )
        ))
    }

    func response(for message: RendererBridgeScriptMessage) -> (Any?, String?) {
        guard message.isExpectedContentWorld else {
            return (nil, "wrong content world")
        }
        guard let text = message.body as? String else {
            return (nil, "malformed envelope")
        }
        do {
            let response = try broker.handlePageEnvelope(
                Data(text.utf8),
                provenance: message.provenance,
                sessionIsReady: sessionIsReady()
            )
            guard let responseText = String(data: response, encoding: .utf8) else {
                return (nil, "invalid response")
            }
            return (responseText, nil)
        } catch {
            DebugLog.reader("renderer bridge request denied: \(String(describing: error))")
            return (nil, "request denied")
        }
    }
}

extension RendererContentWorldBroker {
    static func inputBootstrapScript(input: RendererBridgeInput, contentWorld: WKContentWorld) -> WKUserScript {
        let encodedInput: Data
        do {
            encodedInput = try JSONEncoder().encode(input)
        } catch {
            preconditionFailure("RendererBridgeInput must remain encodable: \(error)")
        }
        let inputJSON = String(decoding: encodedInput, as: UTF8.self)
        let source = "document.documentElement.dataset.rendererInput = \(String(reflecting: inputJSON));"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld)
    }

    static func pageRelayScript(contentWorld: WKContentWorld) -> WKUserScript {
        let source = """
        window.addEventListener("message", function(event) {
            if (event.source !== window || !event.data || typeof event.data.rendererBridge !== "string") { return; }
            const reply = window.webkit.messageHandlers["\(WikiAppWebViewPolicy.isolatedMessageHandlerName)"].postMessage(event.data.rendererBridge);
            if (reply && typeof reply.then === "function") {
                reply.then(function(value) {
                    window.postMessage({rendererBridgeResponse: value}, "*");
                });
            }
        });
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld)
    }
}
#endif

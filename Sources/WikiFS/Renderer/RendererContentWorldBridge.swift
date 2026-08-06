#if os(macOS)
import Foundation
import WebKit
import WikiFSCore

// pattern: Imperative Shell

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

    init(sessionID: RendererSessionID, capability: RendererSessionCapability, inputReader: RendererAuthorizedInputReader) {
        self.sessionID = sessionID
        windowID = UUID()
        self.capability = capability
        self.inputReader = inputReader
        authorizer = RendererBridgeAuthorizer(
            capability: capability,
            sessionID: sessionID,
            windowID: windowID,
            authorizedInput: inputReader.authorizedInput
        )
    }

    func handlePageEnvelope(_ envelope: Data, isMainFrame: Bool, sessionIsReady: Bool) throws -> Data {
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
        let frameID = isMainFrame ? mainFrameID : UUID()
        let context = RendererBridgeAuthorizationContext(
            sessionID: sessionID,
            windowID: windowID,
            frameID: frameID,
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

    func close() { isClosed = true }
}

/// Receives only messages registered in the session's isolated content world.
/// A separate user script relays page `postMessage` values into this handler.
@MainActor
final class RendererScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private let broker: RendererContentWorldBroker
    private let sessionIsReady: () -> Bool

    init(broker: RendererContentWorldBroker, sessionIsReady: @escaping () -> Bool) {
        self.broker = broker
        self.sessionIsReady = sessionIsReady
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        do {
            _ = try broker.handlePageEnvelope(Data(text.utf8), isMainFrame: message.frameInfo.isMainFrame, sessionIsReady: sessionIsReady())
        } catch {
            DebugLog.reader("renderer bridge request denied: \(String(describing: error))")
        }
    }
}

extension RendererContentWorldBroker {
    static func pageRelayScript(contentWorld: WKContentWorld) -> WKUserScript {
        let source = """
        window.addEventListener("message", function(event) {
            if (event.source !== window || !event.data || typeof event.data.rendererBridge !== "string") { return; }
            window.webkit.messageHandlers["\(WikiAppWebViewPolicy.isolatedMessageHandlerName)"].postMessage(event.data.rendererBridge);
        });
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld)
    }
}
#endif

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
    private let assetReader: RendererAuthorizedAssetReader?
    private let allowedNavigationTargetKinds: Set<RendererHostNavigationTargetKind>
    private let routeNavigation: @MainActor (RendererNavigationTarget) -> Void
    private var navigationActivationAuthorizer = RendererNavigationActivationAuthorizer()
    private var navigationID: UInt64 = 0
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
        assetReader: RendererAuthorizedAssetReader? = nil,
        allowedNavigationTargetKinds: Set<RendererHostNavigationTargetKind> = [],
        routeNavigation: @escaping @MainActor (RendererNavigationTarget) -> Void = { _ in },
        expectedOrigin: URL = URL(string: "renderer-package://package")!
    ) {
        self.sessionID = sessionID
        windowID = UUID()
        self.capability = capability
        self.inputReader = inputReader
        self.assetReader = assetReader
        self.allowedNavigationTargetKinds = allowedNavigationTargetKinds
        self.routeNavigation = routeNavigation
        self.expectedOrigin = (expectedOrigin.scheme ?? "", expectedOrigin.host ?? "")
        authorizer = RendererBridgeAuthorizer(
            capability: capability,
            sessionID: sessionID,
            windowID: windowID,
            authorizedInput: inputReader.authorizedInput,
            allowedNavigationTargetKinds: allowedNavigationTargetKinds,
            admittedAssetReferences: assetReader?.admittedReferences ?? []
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
        return try handleEnvelope(envelope, sessionIsReady: sessionIsReady)
    }

    /// Frame-scoped entry for reader DOM embeds: identical authorization to
    /// `handlePageEnvelope` except the caller has already validated the
    /// subframe's token origin and generation (the reader frame registry),
    /// so a non-main frame is expected here rather than rejected.
    func handleSubframeEnvelope(
        _ envelope: Data,
        sessionIsReady: Bool
    ) throws -> Data {
        try handleEnvelope(envelope, sessionIsReady: sessionIsReady)
    }

    private func handleEnvelope(
        _ envelope: Data,
        sessionIsReady: Bool
    ) throws -> Data {
        guard envelope.count <= WikiAppWebViewPolicy.maximumBridgeMessageByteCount else {
            throw RendererBridgeAuthorizationError.oversizedEnvelope
        }
        let pageEnvelope: RendererBridgePageEnvelope
        do {
            pageEnvelope = try RendererBridgeEnvelope.decodePageEnvelope(from: envelope)
        } catch {
            do {
                pageEnvelope = .input(try RendererBridgeEnvelope.decodePageRequest(from: envelope))
            } catch {
                throw RendererBridgeAuthorizationError.malformedEnvelope
            }
        }
        let context = RendererBridgeAuthorizationContext(
            sessionID: sessionID,
            windowID: windowID,
            frameID: mainFrameID,
            mainFrameID: mainFrameID
        )
        let response: Data
        switch pageEnvelope {
        case let .input(pageRequest):
            let request = RendererBridgeRequest(
                id: pageRequest.id,
                method: pageRequest.method,
                capability: capability,
                input: pageRequest.input)
            _ = try authorizer.authorize(
                envelope: RendererBridgeEnvelope.encode(request),
                context: context,
                sessionIsReady: sessionIsReady,
                sessionIsClosed: isClosed)
            let payload = try inputReader.read(request.input)
            response = try RendererBridgeEnvelope.encode(.init(id: request.id, payload: payload))
        case let .navigation(pageRequest):
            let request = RendererNavigationRequest(
                id: pageRequest.id,
                method: pageRequest.method,
                capability: capability,
                target: pageRequest.target,
                activationNonce: pageRequest.activationNonce)
            _ = try authorizer.authorizeNavigation(
                envelope: RendererBridgeEnvelope.encode(request),
                context: context,
                sessionIsReady: sessionIsReady,
                sessionIsClosed: isClosed)
            try navigationActivationAuthorizer.redeem(
                nonce: request.activationNonce,
                target: request.target,
                context: navigationActivationContext())
            routeNavigation(request.target)
            response = try RendererBridgeEnvelope.encode(RendererNavigationAcknowledgement(id: request.id))
        case let .asset(pageRequest):
            // Asset requests never pass through the primary input reader, and
            // asset replies never expose primary source bytes.
            guard let assetReader, assetReader.admittedReferences.contains(pageRequest.reference) else {
                throw RendererBridgeAuthorizationError.assetReadUnavailable
            }
            let request = RendererAssetRequest(
                id: pageRequest.id,
                method: pageRequest.method,
                capability: capability,
                reference: pageRequest.reference)
            _ = try authorizer.authorizeAsset(
                envelope: RendererBridgeEnvelope.encode(request),
                context: context,
                sessionIsReady: sessionIsReady,
                sessionIsClosed: isClosed)
            let payload = try assetReader.read(request.reference)
            response = try RendererBridgeEnvelope.encode(RendererAssetResponse(id: request.id, payload: payload))
        }
        guard response.count <= WikiAppWebViewPolicy.maximumBridgeMessageByteCount else {
            throw RendererBridgeAuthorizationError.oversizedPayload
        }
        return response
    }

    func recordTrustedNavigationActivation(for target: RendererNavigationTarget) -> RendererNavigationActivationNonce? {
        guard isClosed == false,
              allowedNavigationTargetKinds.contains(target.kind)
        else { return nil }
        return navigationActivationAuthorizer.recordTrustedActivation(
            target: target,
            context: navigationActivationContext())
    }

    func invalidateNavigationActivations() {
        navigationID &+= 1
        navigationActivationAuthorizer.invalidateAll()
    }

    func close() {
        isClosed = true
        invalidateNavigationActivations()
        inputReader.close()
        assetReader?.close()
    }

    private func navigationActivationContext() -> RendererExternalActivationContext {
        .init(
            sessionID: sessionID,
            windowID: windowID,
            frameID: mainFrameID,
            mainFrameID: mainFrameID,
            navigationID: navigationID)
    }
}

@MainActor
final class RendererNavigationActivationScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let broker: RendererContentWorldBroker
    private let expectedContentWorld: WKContentWorld
    private let validateProvenance: (WKWebView?, WKSecurityOrigin?, Bool) -> Bool

    init(
        broker: RendererContentWorldBroker,
        expectedContentWorld: WKContentWorld,
        validateProvenance: @escaping (WKWebView?, WKSecurityOrigin?, Bool) -> Bool
    ) {
        self.broker = broker
        self.expectedContentWorld = expectedContentWorld
        self.validateProvenance = validateProvenance
    }

    @available(macOS 11.0, *)
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard message.world === expectedContentWorld,
              validateProvenance(message.webView, message.frameInfo.securityOrigin, message.frameInfo.isMainFrame),
              let text = message.body as? String,
              text.utf8.count <= WikiAppWebViewPolicy.maximumBridgeMessageByteCount
        else { return (nil, "activation denied") }
        let target: RendererNavigationTarget
        do {
            target = try JSONDecoder().decode(RendererNavigationTarget.self, from: Data(text.utf8))
        } catch {
            DebugLog.reader("renderer host-navigation activation target decode denied")
            return (nil, "activation denied")
        }
        guard let nonce = broker.recordTrustedNavigationActivation(for: target)
        else { return (nil, "activation denied") }
        return (nonce.rawValue, nil)
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

    static func navigationActivationScript(contentWorld: WKContentWorld) -> WKUserScript {
        let source = """
        (function() {
          var requestSequence = 0;
          function targetElement(event) {
            var path = event.composedPath ? event.composedPath() : [];
            for (var i = 0; i < path.length; i += 1) {
              var node = path[i];
              if (node && node.dataset && typeof node.dataset.rendererHostNavigation === 'string') return node;
            }
            return null;
          }
          function observe(event) {
            if (!event.isTrusted || window.top !== window) return;
            var element = targetElement(event);
            if (!element) return;
            var targetJSON = element.dataset.rendererHostNavigation;
            var target;
            try { target = JSON.parse(targetJSON); } catch (_) { return; }
            var activation = window.webkit.messageHandlers["\(WikiAppWebViewPolicy.hostNavigationActivationHandlerName)"].postMessage(targetJSON);
            if (!activation || typeof activation.then !== 'function') return;
            activation.then(function(nonce) {
              if (typeof nonce !== 'string') return;
              var request = {
                navigation: {
                  _0: {
                    id: {rawValue: 'navigation-' + String(++requestSequence)},
                    method: 'host.navigate',
                    target: target,
                    activationNonce: {rawValue: nonce}
                  }
                }
              };
              var reply = window.webkit.messageHandlers["\(WikiAppWebViewPolicy.isolatedMessageHandlerName)"].postMessage(JSON.stringify(request));
              if (reply && typeof reply.then === 'function') {
                reply.then(function(value) { window.postMessage({rendererNavigationResponse: value}, '*'); });
              }
            });
          }
          window.addEventListener('pointerup', observe, true);
          window.addEventListener('keydown', function(event) {
            if (event.key === 'Enter' || event.key === ' ') observe(event);
          }, true);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld)
    }

    static func pageRelayScript(contentWorld: WKContentWorld) -> WKUserScript {
        let source = """
        window.addEventListener("message", function(event) {
            if (event.source !== window || !event.data || typeof event.data.rendererBridge !== "string") { return; }
            const reply = window.webkit.messageHandlers["\\(WikiAppWebViewPolicy.isolatedMessageHandlerName)"].postMessage(event.data.rendererBridge);
            if (reply && typeof reply.then === "function") {
                reply.then(function(value) {
                    window.postMessage({rendererBridgeResponse: value}, "*");
                });
            }
        });
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld)
    }

    /// Document-start bootstrap for reader DOM-embed frames. Injected with
    /// `forMainFrameOnly: false` and content world `.page`, but the reader's
    /// message handler only honors envelopes whose frame origin host equals
    /// the admitted frame token, so unrelated frames' scripts are inert.
    /// Exposes only the authorized input selector — bytes stay behind
    /// `input.read`, matching the package contract.
    /// Document-start bootstrap for reader DOM-embed frames. Injected with
    /// Frame-scoped input bootstrap **JS** for reader DOM-embed frames. The
    /// reader router serves this as `renderer-input.js` (the package CSP
    /// allows external renderer-package: scripts but blocks inline ones, and
    /// WKUserScripts added post-load don't run in subframes). The script
    /// exits unless the frame host equals the admitted token; exposes only
    /// the authorized input selector and relays envelopes to the reader's
    /// subframe bridge handler.
    static func frameInputBootstrapJS(
        input: RendererBridgeInput,
        expectedOriginHost: String,
        messageHandlerName: String
    ) -> String {
        let encodedInput: Data
        do {
            encodedInput = try JSONEncoder().encode(input)
        } catch {
            preconditionFailure("RendererBridgeInput must remain encodable: \(error)")
        }
        let inputJSON = String(decoding: encodedInput, as: UTF8.self)
        return """
        (function(){
          if (window.location.host !== '\(expectedOriginHost)') { return; }
          document.documentElement.dataset.rendererInput = \(String(reflecting: inputJSON));
          window.addEventListener("message", function(event) {
            if (event.source !== window || !event.data || typeof event.data.rendererBridge !== "string") { return; }
            var reply = window.webkit.messageHandlers["\(messageHandlerName)"].postMessage(event.data.rendererBridge);
            if (reply && typeof reply.then === "function") {
              reply.then(function(value) {
                window.postMessage({rendererBridgeResponse: value}, "*");
              });
            }
          });
        })();
        """
    }

    /// Frame-scoped subframe bridge for reader DOM embeds. Registered once on
    /// the reader webview in the `.page` content world; honors only envelopes
    /// whose frame origin host equals an admitted frame token (validated by
    /// the reader frame registry) and replies into the sending frame.
    @MainActor
    final class ReaderSubframeBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
        private let validate: (WKFrameInfo, String) -> RendererContentWorldBroker?

        init(validate: @escaping (WKFrameInfo, String) -> RendererContentWorldBroker?) {
            self.validate = validate
        }

        @available(macOS 11.0, *)
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            guard let text = message.body as? String,
                  text.utf8.count <= WikiAppWebViewPolicy.maximumBridgeMessageByteCount
            else {
                DebugLog.reader("subframe bridge: oversized or non-string body")
                return (nil, "request denied")
            }
            let originHost = message.frameInfo.securityOrigin.host
            guard let broker = validate(message.frameInfo, originHost) else {
                DebugLog.reader("subframe bridge: rejected origin \(originHost)")
                return (nil, "request denied")
            }
            do {
                let response = try broker.handleSubframeEnvelope(
                    Data(text.utf8), sessionIsReady: true)
                guard let responseText = String(data: response, encoding: .utf8) else {
                    return (nil, "invalid response")
                }
                return (responseText, nil)
            } catch {
                DebugLog.reader("subframe bridge: denied (\(String(describing: error))) envelope[\(text.prefix(200))]")
                return (nil, "request denied")
            }
        }
    }

}
#endif

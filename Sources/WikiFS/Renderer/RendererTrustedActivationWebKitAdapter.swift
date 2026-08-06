#if os(macOS)
import AppKit
import Foundation
import WebKit
import WikiFSCore

// pattern: Imperative Shell

@MainActor
protocol RendererExternalURLOpening {
    func open(_ destination: URL)
}

@MainActor
struct SystemRendererExternalURLOpener: RendererExternalURLOpening {
    func open(_ destination: URL) { NSWorkspace.shared.open(destination) }
}

/// The only shell that can reach the platform opener. Its authorization input
/// is already host-normalized and host-contextualized by the session.
@MainActor
final class RendererExternalLinkRedemptionGate {
    private var authorizer: RendererExternalActivationAuthorizer
    private let opener: any RendererExternalURLOpening

    init(
        opener: any RendererExternalURLOpening,
        clock: any RendererActivationClock = SystemRendererActivationClock(),
        nonceGenerator: any RendererActivationNonceGenerating = SystemRendererActivationNonceGenerator()
    ) {
        self.opener = opener
        authorizer = .init(clock: clock, nonceGenerator: nonceGenerator)
    }

    func recordTrustedActivation(
        destination: RendererExternalDestination,
        context: RendererExternalActivationContext
    ) -> RendererExternalActivationNonce {
        authorizer.recordTrustedActivation(destination: destination, context: context)
    }

    func redeem(
        nonce: RendererExternalActivationNonce?,
        destination: RendererExternalDestination,
        context: RendererExternalActivationContext
    ) throws -> URL {
        let redeemed = try authorizer.redeem(nonce: nonce, destination: destination, context: context)
        opener.open(redeemed.url)
        return redeemed.url
    }

    func invalidateAll(reason: RendererExternalActivationError) {
        authorizer.invalidateAll(reason: reason)
    }
}

@MainActor
final class RendererTrustedActivationScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let expectedContentWorld: WKContentWorld
    private let handle: (URL, WKWebView?, WKSecurityOrigin?, Bool) -> RendererExternalActivationNonce?

    init(
        expectedContentWorld: WKContentWorld,
        handle: @escaping (URL, WKWebView?, WKSecurityOrigin?, Bool) -> RendererExternalActivationNonce?
    ) {
        self.expectedContentWorld = expectedContentWorld
        self.handle = handle
    }

    @available(macOS 11.0, *)
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.world === expectedContentWorld,
              let rawURL = message.body as? String,
              let url = URL(string: rawURL),
              let nonce = handle(url, message.webView, message.frameInfo.securityOrigin, message.frameInfo.isMainFrame)
        else { return (nil, "activation denied") }
        return (nonce.rawValue, nil)
    }
}

@MainActor
final class RendererExternalLinkScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let expectedContentWorld: WKContentWorld
    private let redeem: (RendererExternalActivationNonce?, URL, WKWebView?, WKSecurityOrigin?, Bool) throws -> URL

    init(
        expectedContentWorld: WKContentWorld,
        redeem: @escaping (RendererExternalActivationNonce?, URL, WKWebView?, WKSecurityOrigin?, Bool) throws -> URL
    ) {
        self.expectedContentWorld = expectedContentWorld
        self.redeem = redeem
    }

    @available(macOS 11.0, *)
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.world === expectedContentWorld,
              let text = message.body as? String
        else { return (nil, "request denied") }

        let request: PageRequest
        do {
            request = try JSONDecoder().decode(PageRequest.self, from: Data(text.utf8))
        } catch {
            DebugLog.reader("renderer external-link request decode denied: \(String(describing: error))")
            return (nil, "request denied")
        }
        guard let url = URL(string: request.destination) else {
            return (nil, "request denied")
        }
        do {
            let redeemed = try redeem(
                request.nonce.map(RendererExternalActivationNonce.init(rawValue:)), url,
                message.webView, message.frameInfo.securityOrigin, message.frameInfo.isMainFrame
            )
            return (redeemed.absoluteString, nil)
        } catch {
            DebugLog.reader("renderer external-link request denied: \(String(describing: error))")
            return (nil, "request denied")
        }
    }

    private struct PageRequest: Decodable {
        let nonce: String?
        let destination: String
    }
}

extension RendererTrustedActivationScriptMessageHandler {
    static func observationScript(contentWorld: WKContentWorld) -> WKUserScript {
        let source = """
        (function() {
          function anchorFrom(event) {
            var path = event.composedPath ? event.composedPath() : [];
            for (var i = 0; i < path.length; i += 1) {
              var node = path[i];
              if (node && node.tagName === 'A' && node.href) return node;
            }
            return null;
          }
          function observe(event) {
            if (!event.isTrusted || window.top !== window) return;
            var anchor = anchorFrom(event);
            if (!anchor) return;
            var reply = window.webkit.messageHandlers["\(WikiAppWebViewPolicy.trustedActivationHandlerName)"].postMessage(anchor.href);
            if (reply && typeof reply.then === 'function') {
              reply.then(function(nonce) {
                if (typeof nonce === 'string') window.postMessage({rendererExternalActivation: {nonce: nonce, destination: anchor.href}}, '*');
              });
            }
          }
          window.addEventListener('pointerup', observe, true);
          window.addEventListener('keydown', function(event) {
            if (event.key === 'Enter' || event.key === ' ') observe(event);
          }, true);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld)
    }
}

extension RendererExternalLinkScriptMessageHandler {
    static func pageRelayScript(contentWorld: WKContentWorld) -> WKUserScript {
        let source = """
        window.addEventListener("message", function(event) {
            if (event.source !== window || !event.data || !event.data.rendererExternalLink) { return; }
            const reply = window.webkit.messageHandlers["\(WikiAppWebViewPolicy.externalLinkHandlerName)"].postMessage(JSON.stringify(event.data.rendererExternalLink));
            if (reply && typeof reply.then === "function") {
                reply.then(function(value) {
                    window.postMessage({rendererExternalLinkResponse: value}, "*");
                });
            }
        });
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld)
    }
}
#endif

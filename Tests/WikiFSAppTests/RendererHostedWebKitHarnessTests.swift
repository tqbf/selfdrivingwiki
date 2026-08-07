#if os(macOS)
import Foundation
import Testing

/// Positive control for the live-receiver infrastructure required before a
/// future renderer isolation matrix can make any negative network claim.
///
/// This intentionally uses a permissive configuration. It proves the two
/// independently-owned loopback receivers are live and that WebKit can reach
/// them before a restrictive renderer session is tested against the same seam.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct RendererHostedWebKitHarnessTests {
    @Test
    func permissiveWebKitReachesLiveHTTPAndWebSocketReceivers() async throws {
        let http = try RendererLoopbackObservationServer(protocol: .http)
        let webSocket = try RendererLoopbackObservationServer(protocol: .webSocket)
        defer {
            http.stop()
            webSocket.stop()
        }
        try await http.start()
        try await webSocket.start()
        let httpURL = try #require(http.observationURL)
        let webSocketURL = try #require(webSocket.observationURL)
        #expect(webSocketURL.scheme == "wss")
        try http.hostDocument("""
        <!doctype html>
        <meta charset="utf-8">
        <script>
        window.rendererPositiveControlHTTPState = "pending";
        window.rendererPositiveControlWebSocketState = "pending";
        document.title = "positive-control-started";
        window.rendererPositiveControlStart = () => {
            fetch(\"\(httpURL.absoluteString)\", { cache: "no-store" })
                .then(() => { window.rendererPositiveControlHTTPState = "response-received"; })
                .catch(() => { window.rendererPositiveControlHTTPState = "error"; });
            const socket = new WebSocket(\"\(webSocketURL.absoluteString)\");
            socket.addEventListener("open", () => {
                window.rendererPositiveControlWebSocketState = "open";
                document.title = "websocket-open";
            });
            socket.addEventListener("error", () => {
                window.rendererPositiveControlWebSocketState = "error";
                document.title = "websocket-error";
            });
        };
        </script>
        """)

        let harness = try await RendererHostedWebKitHarness.permissive()
        defer { harness.close() }
        try await harness.loadURL(try #require(http.documentURL))

        _ = try await harness.waitForDocumentTitle("positive-control-started")
        async let httpObservation = http.waitForObservation()
        async let webSocketObservation = webSocket.waitForObservation()
        try await harness.executeJavaScript(
            "window.rendererPositiveControlStart(); 'receivers-started'",
            expectedValue: "receivers-started",
            description: "receiver request initiation")
        let observedHTTP: RendererLoopbackObservationServer.Observation
        let observedWebSocket: RendererLoopbackObservationServer.Observation
        do {
            (observedHTTP, observedWebSocket) = try await (httpObservation, webSocketObservation)
        } catch {
            let browserHTTPState = await harness.readJavaScriptString(
                "String(window.rendererPositiveControlHTTPState)"
            ) ?? "unreadable"
            let browserWebSocketState = await harness.readJavaScriptString(
                "String(window.rendererPositiveControlWebSocketState)"
            ) ?? "unreadable"
            throw RendererHostedWebKitHarness.HarnessError.timeout(
                description: "\(error.localizedDescription); browserHTTP=\(browserHTTPState), "
                    + "browserWebSocket=\(browserWebSocketState); httpServer=\(http.diagnostics), "
                    + "webSocketServer=\(webSocket.diagnostics); webView=\(harness.diagnostics)"
            )
        }
        let httpState = try await harness.waitForJavaScriptString(
            "String(window.rendererPositiveControlHTTPState)",
            expectedValue: "response-received",
            description: "HTTP response completion")
        let webSocketState = try await harness.waitForJavaScriptString(
            "String(window.rendererPositiveControlWebSocketState)",
            expectedValue: "open",
            description: "WebSocket open callback")
        let title = try await harness.waitForDocumentTitle("websocket-open")

        #expect(title == "websocket-open")
        #expect(httpState == "response-received")
        #expect(webSocketState == "open")
        #expect(observedHTTP.token == http.observationToken)
        #expect(observedWebSocket.token == webSocket.observationToken)
        #expect(observedHTTP.transport == .http)
        #expect(observedWebSocket.transport == .webSocket)
    }
}
#endif

#if os(macOS)
import Foundation
import WebKit
import WikiFSCore

// pattern: Imperative Shell

@MainActor
protocol RendererWebViewDataStoreProviding {
    func makeNonPersistentDataStore() -> WKWebsiteDataStore
}

@MainActor
struct SystemRendererWebViewDataStoreProvider: RendererWebViewDataStoreProviding {
    func makeNonPersistentDataStore() -> WKWebsiteDataStore { .nonPersistent() }
}

@MainActor
protocol RendererWebViewCancellable: AnyObject {
    func cancel()
}

@MainActor
protocol RendererWebViewLoadTimeoutScheduling {
    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any RendererWebViewCancellable
}

@MainActor
struct SystemRendererWebViewLoadTimeoutScheduler: RendererWebViewLoadTimeoutScheduling {
    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any RendererWebViewCancellable {
        RendererWebViewTaskHandle(task: Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            operation()
        })
    }
}

@MainActor
private final class RendererWebViewTaskHandle: RendererWebViewCancellable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
}

@MainActor
final class RendererWebViewSessionPermitPool {
    static let shared = RendererWebViewSessionPermitPool()

    private let maximumPermits: Int
    private var activePermits = 0

    init(maximumPermits: Int = WikiAppWebViewPolicy.maximumConcurrentSessions) {
        self.maximumPermits = maximumPermits
    }

    func acquire() -> RendererWebViewSessionPermit? {
        guard activePermits < maximumPermits else { return nil }
        activePermits += 1
        return RendererWebViewSessionPermit(pool: self)
    }

    fileprivate func release() { activePermits = max(0, activePermits - 1) }
    var activePermitCount: Int { activePermits }
}

@MainActor
final class RendererWebViewSessionPermit {
    private weak var pool: RendererWebViewSessionPermitPool?
    private var isReleased = false

    fileprivate init(pool: RendererWebViewSessionPermitPool) { self.pool = pool }

    func release() {
        guard isReleased == false else { return }
        isReleased = true
        pool?.release()
    }
}

@MainActor
struct WikiAppWebViewConfigurationFactory {
    struct Configuration {
        let webViewConfiguration: WKWebViewConfiguration
        let dataStore: WKWebsiteDataStore
        let userContentController: WKUserContentController
        let contentWorld: WKContentWorld
        let schemeHandler: RendererPackageSchemeHandler
    }

    private let dataStores: any RendererWebViewDataStoreProviding

    init(dataStores: any RendererWebViewDataStoreProviding = SystemRendererWebViewDataStoreProvider()) {
        self.dataStores = dataStores
    }

    func makeConfiguration(
        sessionID: RendererSessionID,
        resourceProvider: any RendererPackageResourceProviding
    ) -> Configuration {
        let dataStore = dataStores.makeNonPersistentDataStore()
        let userContentController = WKUserContentController()
        let contentWorld = WKContentWorld.world(
            name: "\(WikiAppWebViewPolicy.isolatedContentWorldNamePrefix).\(sessionID.rawValue.uuidString)"
        )
        let schemeHandler = RendererPackageSchemeHandler(resourceProvider: resourceProvider)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController = userContentController
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: RendererPackageScheme.name)
        return Configuration(
            webViewConfiguration: configuration,
            dataStore: dataStore,
            userContentController: userContentController,
            contentWorld: contentWorld,
            schemeHandler: schemeHandler
        )
    }
}

/// Main-actor owner for one ephemeral renderer WebView. This slice observes
/// lifecycle callbacks only. Navigation and bridge authorization are deferred.
@MainActor
final class WikiAppWebViewSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let entryURL: URL
    private let resourceProvider: any RendererPackageResourceProviding
    private let configurationFactory: WikiAppWebViewConfigurationFactory
    private let timeoutScheduler: any RendererWebViewLoadTimeoutScheduling
    private let permits: RendererWebViewSessionPermitPool
    private let bridgeFactory: ((RendererSessionID) -> RendererContentWorldBroker)?

    private var machine: WikiAppWebViewSessionStateMachine
    private var configuration: WikiAppWebViewConfigurationFactory.Configuration?
    private var timeoutHandle: (any RendererWebViewCancellable)?
    private var permit: RendererWebViewSessionPermit?
    private var bridge: RendererContentWorldBroker?
    private var scriptMessageHandler: RendererScriptMessageHandler?
    private var requestGeneration = 0
    private(set) var webView: WKWebView?

    init(
        sessionID: RendererSessionID = .init(rawValue: UUID()),
        entryURL: URL,
        resourceProvider: any RendererPackageResourceProviding,
        configurationFactory: WikiAppWebViewConfigurationFactory = .init(),
        timeoutScheduler: any RendererWebViewLoadTimeoutScheduling = SystemRendererWebViewLoadTimeoutScheduler(),
        permits: RendererWebViewSessionPermitPool? = nil,
        bridgeFactory: ((RendererSessionID) -> RendererContentWorldBroker)? = nil
    ) {
        self.entryURL = entryURL
        self.resourceProvider = resourceProvider
        self.configurationFactory = configurationFactory
        self.timeoutScheduler = timeoutScheduler
        self.permits = permits ?? .shared
        self.bridgeFactory = bridgeFactory
        machine = .init(sessionID: sessionID)
    }

    isolated deinit {
        releaseOwnedResources()
    }

    var state: WikiAppWebViewSessionState { machine.state }

    func start() {
        guard machine.start() else { return }
        guard isValidEntryURL else {
            machine.fail(sessionID: machine.sessionID, kind: .invalidEntryURL)
            return
        }
        guard let permit = permits.acquire() else {
            machine.fail(sessionID: machine.sessionID, kind: .concurrencyLimitReached)
            return
        }
        self.permit = permit
        requestGeneration &+= 1
        let requestGeneration = requestGeneration
        let configuration = configurationFactory.makeConfiguration(
            sessionID: machine.sessionID,
            resourceProvider: resourceProvider
        )
        self.configuration = configuration
        if let bridgeFactory {
            let bridge = bridgeFactory(machine.sessionID)
            let handler = RendererScriptMessageHandler(
                broker: bridge,
                expectedContentWorld: configuration.contentWorld
            ) { [weak self] in
                self?.isReadyForBridge ?? false
            }
            configuration.userContentController.addScriptMessageHandler(
                handler,
                contentWorld: configuration.contentWorld,
                name: WikiAppWebViewPolicy.isolatedMessageHandlerName
            )
            configuration.userContentController.addUserScript(
                RendererContentWorldBroker.pageRelayScript(contentWorld: configuration.contentWorld)
            )
            self.bridge = bridge
            scriptMessageHandler = handler
        }
        let webView = WKWebView(frame: .zero, configuration: configuration.webViewConfiguration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        bridge?.bind(to: webView)
        self.webView = webView
        let sessionID = machine.sessionID
        timeoutHandle = timeoutScheduler.schedule(after: WikiAppWebViewPolicy.loadTimeout) { [weak self] in
            self?.timeoutFired(sessionID: sessionID, requestGeneration: requestGeneration)
        }
        webView.load(URLRequest(url: entryURL))
    }

    func close() {
        guard machine.close() else { return }
        releaseOwnedResources()
    }

    private func releaseOwnedResources() {
        requestGeneration &+= 1
        timeoutHandle?.cancel()
        timeoutHandle = nil
        webView?.stopLoading()
        bridge?.close()
        bridge = nil
        scriptMessageHandler = nil
        configuration?.schemeHandler.close()
        if let configuration {
            configuration.userContentController.removeScriptMessageHandler(
                forName: WikiAppWebViewPolicy.isolatedMessageHandlerName,
                contentWorld: configuration.contentWorld
            )
            configuration.userContentController.removeAllUserScripts()
        }
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        configuration = nil
        permit?.release()
        permit = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard self.webView === webView, isLoading else { return }
        timeoutHandle?.cancel()
        timeoutHandle = nil
        requestGeneration &+= 1
        machine.markReady(sessionID: machine.sessionID)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        failLoading(.navigationFailed, webView: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        failLoading(.navigationFailed, webView: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failLoading(.webContentProcessTerminated, webView: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard self.webView === webView else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(isAllowedPackageURL(navigationAction.request.url) ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard self.webView === webView,
              isAllowedPackageURL(navigationResponse.response.url)
        else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    private func isAllowedPackageURL(_ url: URL?) -> Bool {
        RendererNavigationPolicy.decision(for: url, entryURL: entryURL) == .allowPackageResource
    }

    private var isValidEntryURL: Bool {
        guard entryURL.scheme == RendererPackageScheme.name,
              entryURL.host == "package"
        else { return false }
        do {
            _ = try RendererPackageScheme.request(from: entryURL)
            return true
        } catch {
            DebugLog.reader("renderer package entry URL rejected by package scheme validation.")
            return false
        }
    }

    private var isLoading: Bool {
        guard case .loading = machine.state else { return false }
        return true
    }

    private var isReadyForBridge: Bool {
        if case .ready = machine.state { return true }
        return false
    }

    private func timeoutFired(sessionID: RendererSessionID, requestGeneration: Int) {
        guard self.requestGeneration == requestGeneration, machine.sessionID == sessionID, isLoading else { return }
        failLoading(.loadTimedOut)
    }

    private func failLoading(_ kind: RendererSessionFailureKind, webView: WKWebView? = nil) {
        guard isLoading else { return }
        if let webView, self.webView !== webView { return }
        machine.fail(sessionID: machine.sessionID, kind: kind)
        releaseOwnedResources()
    }
}
#endif

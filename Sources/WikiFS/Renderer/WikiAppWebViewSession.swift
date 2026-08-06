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

    func makeConfiguration(resourceProvider: any RendererPackageResourceProviding) -> Configuration {
        let dataStore = dataStores.makeNonPersistentDataStore()
        let userContentController = WKUserContentController()
        let contentWorld = WKContentWorld.world(name: WikiAppWebViewPolicy.isolatedContentWorldName)
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

    private var machine: WikiAppWebViewSessionStateMachine
    private var configuration: WikiAppWebViewConfigurationFactory.Configuration?
    private var timeoutHandle: (any RendererWebViewCancellable)?
    private var operationHandles: [any RendererWebViewCancellable] = []
    private var permit: RendererWebViewSessionPermit?
    private var requestGeneration = 0
    private(set) var webView: WKWebView?

    init(
        sessionID: RendererSessionID = .init(rawValue: UUID()),
        entryURL: URL,
        resourceProvider: any RendererPackageResourceProviding,
        configurationFactory: WikiAppWebViewConfigurationFactory = .init(),
        timeoutScheduler: any RendererWebViewLoadTimeoutScheduling = SystemRendererWebViewLoadTimeoutScheduler(),
        permits: RendererWebViewSessionPermitPool = .init()
    ) {
        self.entryURL = entryURL
        self.resourceProvider = resourceProvider
        self.configurationFactory = configurationFactory
        self.timeoutScheduler = timeoutScheduler
        self.permits = permits
        machine = .init(sessionID: sessionID)
    }

    var state: WikiAppWebViewSessionState { machine.state }

    func start() {
        guard machine.start() else { return }
        guard entryURL.scheme == RendererPackageScheme.name else {
            machine.fail(sessionID: machine.sessionID, kind: .invalidEntryURL)
            return
        }
        guard let permit = permits.acquire() else {
            machine.fail(sessionID: machine.sessionID, kind: .concurrencyLimitReached)
            return
        }
        self.permit = permit
        let configuration = configurationFactory.makeConfiguration(resourceProvider: resourceProvider)
        self.configuration = configuration
        let webView = WKWebView(frame: .zero, configuration: configuration.webViewConfiguration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        let sessionID = machine.sessionID
        timeoutHandle = timeoutScheduler.schedule(after: WikiAppWebViewPolicy.loadTimeout) { [weak self] in
            self?.timeoutFired(sessionID: sessionID)
        }
        webView.load(URLRequest(url: entryURL))
    }

    func close() {
        guard machine.close() else { return }
        requestGeneration &+= 1
        timeoutHandle?.cancel()
        timeoutHandle = nil
        for handle in operationHandles { handle.cancel() }
        operationHandles.removeAll()
        webView?.stopLoading()
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
        timeoutHandle?.cancel()
        timeoutHandle = nil
        machine.markReady(sessionID: machine.sessionID)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        failLoading(.navigationFailed)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        failLoading(.navigationFailed)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failLoading(.webContentProcessTerminated)
    }

    private func timeoutFired(sessionID: RendererSessionID) {
        machine.fail(sessionID: sessionID, kind: .loadTimedOut)
        close()
    }

    private func failLoading(_ kind: RendererSessionFailureKind) {
        timeoutHandle?.cancel()
        timeoutHandle = nil
        machine.fail(sessionID: machine.sessionID, kind: kind)
    }
}
#endif

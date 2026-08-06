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
    private let installedPackage: RendererPackageReservation?
    private let failureRecorder: RendererSessionFailureRecording?
    private let bridgeFactory: ((RendererSessionID) throws -> RendererContentWorldBroker)?

    private var machine: WikiAppWebViewSessionStateMachine
    private var configuration: WikiAppWebViewConfigurationFactory.Configuration?
    private var timeoutHandle: (any RendererWebViewCancellable)?
    private var permit: RendererWebViewSessionPermit?
    private var bridge: RendererContentWorldBroker?
    private var scriptMessageHandler: RendererScriptMessageHandler?
    private var trustedActivationHandler: RendererTrustedActivationScriptMessageHandler?
    private var externalLinkHandler: RendererExternalLinkScriptMessageHandler?
    private let externalLinkRedemptionGate: RendererExternalLinkRedemptionGate
    private let windowID = UUID()
    private let mainFrameID = UUID()
    private var navigationID: UInt64 = 0
    private var requestGeneration = 0
    private(set) var webView: WKWebView?

    init(
        sessionID: RendererSessionID = .init(rawValue: UUID()),
        entryURL: URL,
        resourceProvider: any RendererPackageResourceProviding,
        configurationFactory: WikiAppWebViewConfigurationFactory = .init(),
        timeoutScheduler: any RendererWebViewLoadTimeoutScheduling = SystemRendererWebViewLoadTimeoutScheduler(),
        permits: RendererWebViewSessionPermitPool? = nil,
        installedPackage: RendererPackageReservation? = nil,
        failureRecorder: RendererSessionFailureRecording? = nil,
        bridgeFactory: ((RendererSessionID) throws -> RendererContentWorldBroker)? = nil,
        externalURLOpener: any RendererExternalURLOpening = SystemRendererExternalURLOpener(),
        activationClock: any RendererActivationClock = SystemRendererActivationClock(),
        activationNonceGenerator: any RendererActivationNonceGenerating = SystemRendererActivationNonceGenerator()
    ) {
        self.entryURL = entryURL
        self.resourceProvider = resourceProvider
        self.configurationFactory = configurationFactory
        self.timeoutScheduler = timeoutScheduler
        self.permits = permits ?? .shared
        self.installedPackage = installedPackage
        self.failureRecorder = failureRecorder
        self.bridgeFactory = bridgeFactory
        externalLinkRedemptionGate = .init(
            opener: externalURLOpener,
            clock: activationClock,
            nonceGenerator: activationNonceGenerator
        )
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
            do {
                let bridge = try bridgeFactory(machine.sessionID)
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
            } catch {
                DebugLog.reader("Renderer bridge bootstrap failed.")
                failLoading(.bridgeBootstrapFailed)
                return
            }
        }
        let trustedActivationHandler = RendererTrustedActivationScriptMessageHandler(
            expectedContentWorld: configuration.contentWorld
        ) { [weak self] url, webView, securityOrigin, isMainFrame in
            self?.recordTrustedActivation(url: url, webView: webView, securityOrigin: securityOrigin, isMainFrame: isMainFrame)
        }
        let externalLinkHandler = RendererExternalLinkScriptMessageHandler(
            expectedContentWorld: configuration.contentWorld
        ) { [weak self] nonce, url, webView, securityOrigin, isMainFrame in
            guard let self else { throw RendererExternalActivationError.sessionClosed }
            return try self.redeemExternalLink(nonce: nonce, url: url, webView: webView, securityOrigin: securityOrigin, isMainFrame: isMainFrame)
        }
        configuration.userContentController.addScriptMessageHandler(
            trustedActivationHandler, contentWorld: configuration.contentWorld, name: WikiAppWebViewPolicy.trustedActivationHandlerName
        )
        configuration.userContentController.addScriptMessageHandler(
            externalLinkHandler, contentWorld: configuration.contentWorld, name: WikiAppWebViewPolicy.externalLinkHandlerName
        )
        configuration.userContentController.addUserScript(RendererTrustedActivationScriptMessageHandler.observationScript(contentWorld: configuration.contentWorld))
        self.trustedActivationHandler = trustedActivationHandler
        self.externalLinkHandler = externalLinkHandler
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
        releaseOwnedResources(invalidation: .sessionClosed)
    }

    private func releaseOwnedResources(invalidation: RendererExternalActivationError = .sessionClosed) {
        requestGeneration &+= 1
        navigationID &+= 1
        externalLinkRedemptionGate.invalidateAll(reason: invalidation)
        timeoutHandle?.cancel()
        timeoutHandle = nil
        webView?.stopLoading()
        bridge?.close()
        bridge = nil
        scriptMessageHandler = nil
        trustedActivationHandler = nil
        externalLinkHandler = nil
        configuration?.schemeHandler.close()
        if let configuration {
            configuration.userContentController.removeScriptMessageHandler(
                forName: WikiAppWebViewPolicy.isolatedMessageHandlerName,
                contentWorld: configuration.contentWorld
            )
            configuration.userContentController.removeScriptMessageHandler(
                forName: WikiAppWebViewPolicy.trustedActivationHandlerName, contentWorld: configuration.contentWorld
            )
            configuration.userContentController.removeScriptMessageHandler(
                forName: WikiAppWebViewPolicy.externalLinkHandlerName, contentWorld: configuration.contentWorld
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
            externalLinkRedemptionGate.invalidateAll(reason: .wrongWindow)
            decisionHandler(.cancel)
            return
        }
        invalidateForNavigation()
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
            externalLinkRedemptionGate.invalidateAll(reason: .navigationInvalidated)
            decisionHandler(.cancel)
            return
        }
        invalidateForNavigation()
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
            let request = try RendererPackageScheme.request(from: entryURL)
            guard let installedPackage else { return true }
            guard request.packageID == installedPackage.packageID,
                  request.version == installedPackage.version
            else {
                DebugLog.reader("Renderer package entry URL did not match its installed package reservation.")
                return false
            }
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
        if let webView, self.webView !== webView { return }
        externalLinkRedemptionGate.invalidateAll(reason: .sessionFailed)
        guard machine.fail(sessionID: machine.sessionID, kind: kind) else { return }
        recordInstalledRendererFailure(kind)
        releaseOwnedResources(invalidation: .sessionFailed)
    }

    private func invalidateForNavigation() {
        navigationID &+= 1
        externalLinkRedemptionGate.invalidateAll(reason: .navigationInvalidated)
    }

    private func recordTrustedActivation(
        url: URL, webView: WKWebView?, securityOrigin: WKSecurityOrigin?, isMainFrame: Bool
    ) -> RendererExternalActivationNonce? {
        guard self.webView === webView,
              isReadyForBridge,
              hasExpectedPackageOrigin(securityOrigin),
              isMainFrame,
              let destination = RendererExternalDestination(url: url)
        else {
            externalLinkRedemptionGate.invalidateAll(reason: isMainFrame ? .wrongWindow : .nonMainFrame)
            return nil
        }
        return externalLinkRedemptionGate.recordTrustedActivation(destination: destination, context: externalActivationContext())
    }

    private func redeemExternalLink(
        nonce: RendererExternalActivationNonce?, url: URL, webView: WKWebView?, securityOrigin: WKSecurityOrigin?, isMainFrame: Bool
    ) throws -> URL {
        guard self.webView === webView, hasExpectedPackageOrigin(securityOrigin) else {
            externalLinkRedemptionGate.invalidateAll(reason: .wrongWindow)
            throw RendererExternalActivationError.wrongWindow
        }
        guard isMainFrame else {
            externalLinkRedemptionGate.invalidateAll(reason: .nonMainFrame)
            throw RendererExternalActivationError.nonMainFrame
        }
        guard isReadyForBridge else { throw RendererExternalActivationError.navigationInvalidated }
        guard let destination = RendererExternalDestination(url: url) else {
            throw RendererExternalActivationError.destinationMismatch
        }
        return try externalLinkRedemptionGate.redeem(nonce: nonce, destination: destination, context: externalActivationContext())
    }

    private func externalActivationContext() -> RendererExternalActivationContext {
        .init(sessionID: machine.sessionID, windowID: windowID, frameID: mainFrameID, mainFrameID: mainFrameID, navigationID: navigationID)
    }

    private func hasExpectedPackageOrigin(_ origin: WKSecurityOrigin?) -> Bool {
        origin?.protocol == RendererPackageScheme.name && origin?.host == "package"
    }

    private func recordInstalledRendererFailure(_ kind: RendererSessionFailureKind) {
        guard let failureRecorder,
              let installedPackage,
              kind.installedRendererFailureCause != nil
        else { return }
        let failure = RendererSessionFailure(sessionID: machine.sessionID, kind: kind)
        // This must outlive the WebView teardown so a terminal callback cannot
        // lose its accounting event when the host immediately closes the view.
        Task {
            await failureRecorder(failure, installedPackage)
        }
    }
}
#endif

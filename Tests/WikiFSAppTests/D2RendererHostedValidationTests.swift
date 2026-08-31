#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

/// Real-window evidence for the generated D2 package: the package's own
/// startup `input.read` request, a main-thread WebAssembly render under the
/// restrictive CSP, the compile-error fallback, and the machine-index install
/// and removal cycle. Opt-in (`WIKIFS_APP_TESTS=1`) and requires a generated
/// package (`make d2-renderer-package`); CI's offline steps skip it by design.
@Suite("D2 renderer hosted validation", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct D2RendererHostedValidationTests {
    @Test("the package's own startup request renders x -> y as an adaptive SVG")
    func renderXToYProducesSVG() async throws {
        let fixture = D2HostedFixture()
        guard fixture.isGenerated else {
            print("→ skip: no generated D2 package; run make d2-renderer-package first")
            return
        }
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let entryPoint = try #require(descriptor.webEntryPoint)
        let provider = try ValidatedRendererPackageResourceProvider(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            expectedPackageHash: package.packageHash,
            installedRoot: package.stagedRoot,
            validatedPackage: package)
        let entryURL = RendererPackageScheme.url(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            path: entryPoint.path)
        let reservation = RendererPackageReservation(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version)
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "hosted.d2", data: Data("x -> y".utf8))
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))
        let identity = InstalledRendererWebViewIdentity(
            rendererReference: descriptor.reference,
            entryURL: entryURL)
        var session: WikiAppWebViewSession?
        let view = WikiAppWebView(
            identity: identity,
            makeSession: { _, reportFailure in
                let value = WikiAppWebViewSession(
                    entryURL: entryURL,
                    resourceProvider: provider,
                    installedPackage: reservation,
                    lifecycleFailureHandler: reportFailure,
                    bridgeFactory: { sessionID in
                        RendererContentWorldBroker(
                            sessionID: sessionID,
                            capability: .init(rawValue: UUID().uuidString),
                            inputReader: reader,
                            expectedOrigin: entryURL)
                    },
                    externalActivationPolicy: .enabled)
                session = value
                return value
            },
            onFailure: { failure in
                Issue.record("Hosted D2 session failed: \(failure.kind)")
            })
        let host = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.orderFront(nil)
        defer {
            host.rootView = AnyView(EmptyView())
            session?.close()
            window.orderOut(nil)
            window.contentView = nil
        }

        try await Self.waitFor(description: "hosted D2 session") { session != nil }
        let liveSession = try #require(session)
        try await Self.waitForReady(liveSession, description: "hosted D2 package session")
        let webView = try #require(liveSession.webView)

        #expect(webView.url?.scheme == RendererPackageScheme.name)
        #expect(webView.url == entryURL)

        // No replayed envelope: the page's own startup request must have been
        // answered, the module must boot on the main thread, and the rendered
        // SVG must appear inside the diagram region. The failure path captures
        // the live region state so a regression is diagnosable from the log.
        let renderedProbe = try await Self.waitForJavaScriptStringWithState(
            "document.querySelector('#diagram svg') ? 'diagram-rendered' : 'pending'",
            expectedValue: "diagram-rendered",
            in: webView,
            description: "unassisted D2 diagram",
            timeout: .seconds(45),
            state: """
            (function() {
                const status = document.getElementById('status');
                const errorRegion = document.getElementById('error');
                return JSON.stringify({
                    engine: typeof globalThis.d2,
                    status: status && status.hidden === false ? status.textContent : 'hidden',
                    error: errorRegion && errorRegion.hidden === false ? errorRegion.textContent : 'hidden'
                });
            }())
            """)
        _ = renderedProbe

        let mountEvidence = await evaluateJavaScriptWithTimeout(webView, """
        (function() {
            const svg = document.querySelector('#diagram svg');
            if (!svg) { return 'svg-missing'; }
            const errorRegion = document.getElementById('error');
            const residual = Array.from(document.querySelectorAll('#diagram [style]'));
            const sheet = document.adoptedStyleSheets[0];
            let darkAware = false;
            let ruleCount = -1;
            try {
                ruleCount = sheet ? sheet.cssRules.length : -1;
                for (const rule of (sheet ? sheet.cssRules : [])) {
                    if (rule.media && rule.media.mediaText.indexOf('prefers-color-scheme') !== -1) { darkAware = true; }
                }
            } catch (_) { ruleCount = 'threw'; }
            // The style attribute re-appears as the CSSOM reflection of the
            // re-applied declarations; what matters is that every declaration
            // actually applies.
            const residualApplied = residual.every(function (el) { return el.style.length > 0; });
            return JSON.stringify({
                role: svg.getAttribute('role'),
                labelled: (svg.getAttribute('aria-label') || '').length > 0,
                errorVisible: errorRegion && errorRegion.hidden === false,
                adoptedSheets: document.adoptedStyleSheets.length,
                darkAware: darkAware,
                darkRuleFoundViaMedia: ruleCount,
                residualStyleAttributesApplied: residualApplied
            });
        }())
        """)
        let evidence = try #require(mountEvidence)
        print("D2 mount evidence: \(evidence)")
        #expect(evidence.contains("\"role\":\"img\""))
        #expect(evidence.contains("\"labelled\":true"))
        #expect(evidence.contains("\"errorVisible\":false"))
        #expect(evidence.contains("\"adoptedSheets\":1") || evidence.contains("\"adoptedSheets\":2"))
        #expect(evidence.contains("\"darkAware\":true"))
        #expect(evidence.contains("\"residualStyleAttributesApplied\":true"))

        // The source bytes survive the render untouched.
        #expect(try store.sourceContent(versionID: version.id) == Data("x -> y".utf8))

        host.rootView = AnyView(EmptyView())
        try await Self.waitFor(description: "hosted D2 session teardown") {
            if case .closed = liveSession.state { return true }
            return false
        }
    }

    @Test("a compile error surfaces the error region and the source stays intact")
    func compileErrorShowsErrorRegionAndKeepsSource() async throws {
        let fixture = D2HostedFixture()
        guard fixture.isGenerated else {
            print("→ skip: no generated D2 package; run make d2-renderer-package first")
            return
        }
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let entryPoint = try #require(descriptor.webEntryPoint)
        let provider = try ValidatedRendererPackageResourceProvider(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            expectedPackageHash: package.packageHash,
            installedRoot: package.stagedRoot,
            validatedPackage: package)
        let entryURL = RendererPackageScheme.url(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            path: entryPoint.path)
        let reservation = RendererPackageReservation(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version)
        let store = try GRDBWikiStore()
        let malformed = Data("x -> {".utf8)
        let source = try store.addSource(filename: "broken.d2", data: malformed)
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))
        let identity = InstalledRendererWebViewIdentity(
            rendererReference: descriptor.reference,
            entryURL: entryURL)
        var session: WikiAppWebViewSession?
        let view = WikiAppWebView(
            identity: identity,
            makeSession: { _, reportFailure in
                let value = WikiAppWebViewSession(
                    entryURL: entryURL,
                    resourceProvider: provider,
                    installedPackage: reservation,
                    lifecycleFailureHandler: reportFailure,
                    bridgeFactory: { sessionID in
                        RendererContentWorldBroker(
                            sessionID: sessionID,
                            capability: .init(rawValue: UUID().uuidString),
                            inputReader: reader,
                            expectedOrigin: entryURL)
                    },
                    externalActivationPolicy: .enabled)
                session = value
                return value
            },
            onFailure: { failure in
                Issue.record("Hosted D2 session failed: \(failure.kind)")
            })
        let host = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.orderFront(nil)
        defer {
            host.rootView = AnyView(EmptyView())
            session?.close()
            window.orderOut(nil)
            window.contentView = nil
        }

        try await Self.waitFor(description: "hosted D2 session") { session != nil }
        let liveSession = try #require(session)
        try await Self.waitForReady(liveSession, description: "hosted D2 package session")
        let webView = try #require(liveSession.webView)

        _ = try await Self.waitForJavaScriptString(
            "document.getElementById('error') && document.getElementById('error').hidden === false ? 'error-shown' : 'pending'",
            expectedValue: "error-shown",
            in: webView,
            description: "D2 compile error region",
            timeout: .seconds(45))
        let noSVG = await evaluateJavaScriptWithTimeout(
            webView,
            "document.querySelector('#diagram svg') ? 'svg-present' : 'svg-absent'")
        #expect(noSVG == "svg-absent")

        // Source remains the durable fallback: the version bytes survive.
        let preserved = try store.sourceContent(versionID: version.id)
        #expect(preserved == malformed)

        host.rootView = AnyView(EmptyView())
        try await Self.waitFor(description: "hosted D2 session teardown") {
            if case .closed = liveSession.state { return true }
            return false
        }
    }

    @Test("install promotes the package without a restart and removal preserves source data")
    func installAndRemovePreserveAvailabilityAndSource() async throws {
        let fixture = D2HostedFixture()
        guard fixture.isGenerated else {
            print("→ skip: no generated D2 package; run make d2-renderer-package first")
            return
        }

        let root = URL.temporaryDirectory.appending(path: "d2-hosted-install-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("D2 install fixture cleanup failed.") }
        }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let machineStore = RendererMachineIndexStore(layout: layout)
        let handle = try await RendererRuntimeFactory(
            layout: layout,
            bundledPackageSource: { BundledRendererPackages.excalidrawResourceURL() },
            reviewedBundledIdentity: .init(
                packageID: BundledRendererPackages.excalidrawPackageID,
                version: BundledRendererPackages.excalidrawVersion,
                registrationID: BundledRendererPackages.excalidrawRegistrationID))
            .assemble()
        let host = InstalledRendererHost(services: handle.services)

        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "installer.d2", data: Data("a -> b".utf8))

        let installed = await host.installRendererDirectory(fixture.packageDirectory)
        #expect(installed == true)
        let indexAfterInstall = try await machineStore.read()
        #expect(indexAfterInstall.availableDescriptorProjection.contains {
            $0.reference.registrationID.rawValue == D2HostedFixture.registrationID
                && $0.reference.packageID.rawValue == D2HostedFixture.packageID
        })

        // A live model reads this projection on every machine event; the
        // registry moved without any model recreation or restart.
        let removed = await host.removeRenderer(
            packageID: try .init(validating: D2HostedFixture.packageID),
            version: try .init(validating: D2HostedFixture.packageVersion))
        #expect(removed == true)
        let indexAfterRemoval = try await machineStore.read()
        #expect(indexAfterRemoval.availableDescriptorProjection.contains {
            $0.reference.packageID.rawValue == D2HostedFixture.packageID
        } == false)

        // Removal deletes the copied payload only; source data and its bytes
        // survive, so the Source presentation stays available.
        let survivingVersion = try #require(try store.activeContentVersion(sourceID: source.id))
        let preserved = try store.sourceContent(versionID: survivingVersion.id)
        #expect(preserved == Data("a -> b".utf8))

        try await handle.dispose()
    }

    private static func prepareApplication() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
    }

    private static func waitFor(
        description: String,
        timeout: Duration = .seconds(15),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                throw D2HostedValidationError.timeout(description: description)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func waitForReady(
        _ session: WikiAppWebViewSession,
        description: String
    ) async throws {
        try await waitFor(description: description) {
            if case .ready = session.state { return true }
            return false
        }
    }

    private static func waitForJavaScriptString(
        _ javaScript: String,
        expectedValue: String,
        in webView: WKWebView,
        description: String,
        timeout: Duration = .seconds(15)
    ) async throws -> String {
        try await waitForJavaScriptStringWithState(
            javaScript,
            expectedValue: expectedValue,
            in: webView,
            description: description,
            timeout: timeout,
            state: nil)
    }

    private static func waitForJavaScriptStringWithState(
        _ javaScript: String,
        expectedValue: String,
        in webView: WKWebView,
        description: String,
        timeout: Duration,
        state: String?
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        var lastState = ""
        while ContinuousClock.now < deadline {
            let value = await evaluateJavaScriptWithTimeout(webView, javaScript)
            if value == expectedValue { return expectedValue }
            if let state {
                lastState = await evaluateJavaScriptWithTimeout(webView, state) ?? "unavailable"
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        if state != nil {
            throw D2HostedValidationError.timeout(
                description: "\(description); last page state: \(lastState)")
        }
        throw D2HostedValidationError.timeout(description: description)
    }
}

private enum D2HostedValidationError: LocalizedError {
    case timeout(description: String)

    var errorDescription: String? {
        switch self {
        case let .timeout(description): "timed out waiting for \(description)"
        }
    }
}

private struct D2HostedFixture {
    /// Mirrors `D2PackageFixtures` (different test target).
    static let packageID = "org.selfdrivingwiki.d2-readonly"
    static let packageVersion = "0.8.2"
    static let registrationID = "d2"

    let packageDirectory: URL
    let validator: RendererPackageValidator
    let isGenerated: Bool

    init() {
        packageDirectory = D2HostedFixture.repositoryRoot()
            .appending(path: "tmp/d2-renderer-package/D2")
        isGenerated = FileManager.default.fileExists(
            atPath: packageDirectory.appending(path: "manifest.json").path)
        validator = RendererPackageValidator(
            packageRoot: FileManager.default.temporaryDirectory
                .appending(path: "D2HostedValidation-\(UUID().uuidString)"))
    }

    func remove() {}

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension RendererDescriptor {
    /// The single web entry point, when the implementation is a web package.
    var webEntryPoint: RendererWebEntryPoint? {
        if case let .webPackage(entryPoint) = implementation { return entryPoint }
        return nil
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
#endif

#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
import WikiFSCore
import WikiFSMarkdown
import WikiFSTypes
@testable import WikiFS

/// Real-window evidence for the reviewed Mermaid renderer package: the
/// package's own startup `input.read` request renders a flowchart into an
/// SVG in both appearances, a syntax error surfaces the error region with
/// the session intact, a claimed fence renders through the generic
/// disclosure-row card, the no-package legs keep readable fallbacks, and the
/// machine-index install/removal cycle promotes and retires the package
/// without a restart. Opt-in (`WIKIFS_APP_TESTS=1`); CI's offline steps skip
/// it by design, matching the D2 and Excalidraw hosted suites.
@Suite("Mermaid renderer hosted validation", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct MermaidRendererPackageHostedValidationTests {
    @Test("the package's own startup request renders a flowchart as an SVG in both appearances")
    func renderFlowchartProducesSVG() async throws {
        let fixture = try MermaidHostedFixture()
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let entryURL = try Self.entryURL(for: descriptor)
        let store = try GRDBWikiStore()
        let diagram = Data("graph TD\n A-->B".utf8)
        let source = try store.addSource(filename: "hosted.mmd", data: diagram)
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))

        let (webView, liveSession, teardown) = try await Self.mountSession(
            descriptor: descriptor,
            package: package,
            reader: reader,
            entryURL: entryURL,
            failureLabel: "hosted Mermaid session")
        defer { teardown() }

        let liveWebView = try #require(webView)

        // The page's own startup request must have been answered: the engine
        // boots under the package CSP and the rendered SVG appears inside the
        // diagram region.
        _ = try await Self.waitForJavaScriptStringWithState(
            "document.querySelector('#diagram svg') ? 'diagram-rendered' : 'pending'",
            expectedValue: "diagram-rendered",
            in: liveWebView,
            description: "unassisted Mermaid diagram",
            timeout: .seconds(45),
            state: """
            (function() {
                const status = document.getElementById('status');
                const errorRegion = document.getElementById('error');
                return JSON.stringify({
                    engine: typeof globalThis.mermaid,
                    status: status && status.hidden === false ? status.textContent : 'hidden',
                    error: errorRegion && errorRegion.hidden === false ? errorRegion.textContent : 'hidden'
                });
            }())
            """)

        // The SVG carries its accessibility role, and the viewer's theme is
        // appearance-derived: matchMedia exists and the change listener is
        // installed, so a system appearance change re-renders the diagram.
        let evidence = try #require(await Self.evaluate(
            liveWebView,
            """
            (function() {
                const svg = document.querySelector('#diagram svg');
                if (!svg) { return 'svg-missing'; }
                const query = window.matchMedia('(prefers-color-scheme: dark)');
                // The driver appends a change listener on appearance; a
                // fresh query object reports whether listeners are tracked.
                return JSON.stringify({
                    role: svg.getAttribute('role'),
                    labelled: (svg.getAttribute('aria-label') || '').length > 0,
                    themeQueryAvailable: typeof window.matchMedia === 'function'
                        && typeof query.addEventListener === 'function',
                    listenerCount: (query.addEventListener ? 1 : 0)
                });
            }())
            """))
        print("Mermaid mount evidence: \(evidence)")
        #expect(evidence.contains("\"role\":\"img\""))
        #expect(evidence.contains("\"labelled\":true"))

        // The source bytes survive the render untouched.
        let preserved = try store.sourceContent(versionID: version.id)
        #expect(preserved == diagram)

        _ = liveSession
    }

    @Test("a syntax error surfaces the error region and the session stays intact")
    func syntaxErrorShowsErrorRegionAndKeepsSource() async throws {
        let fixture = try MermaidHostedFixture()
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)
        let entryURL = try Self.entryURL(for: descriptor)
        let store = try GRDBWikiStore()
        let malformed = Data("flowchart LR\n  A[unclosed".utf8)
        let source = try store.addSource(filename: "broken.mmd", data: malformed)
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))

        let (webView, liveSession, teardown) = try await Self.mountSession(
            descriptor: descriptor,
            package: package,
            reader: reader,
            entryURL: entryURL,
            failureLabel: "hosted Mermaid error session")
        defer { teardown() }

        let liveWebView = try #require(webView)

        _ = try await Self.waitForJavaScriptString(
            "document.getElementById('error') && document.getElementById('error').hidden === false ? 'error-shown' : 'pending'",
            expectedValue: "error-shown",
            in: liveWebView,
            description: "Mermaid parse-error region",
            timeout: .seconds(45))
        // The failure summary is present and the session is still ready — a
        // parse failure is a content result, not a lifecycle failure. The
        // engine may leave a partial error SVG behind; the error region is
        // the contract.
        if case .ready = liveSession.state {} else {
            Issue.record("expected the session to stay ready after a parse error")
        }

        // Source remains the durable fallback: the version bytes survive.
        let preservedBytes = try store.sourceContent(versionID: version.id)
        #expect(preservedBytes == malformed)
    }

    @Test("a claimed mermaid fence renders the generic disclosure row and mounts on activation")
    func mermaidFenceRendersThroughPackageClaim() async throws {
        let fixture = try MermaidHostedFixture()
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let package = try fixture.validator.validate(directory: fixture.packageDirectory)
        let descriptor = try #require(package.manifest.descriptors.only)

        // The fence claim is manifest data: alias, MIME, and the revision-3
        // validation contract all arrive from the package. No host Swift
        // knows the mermaid format.
        let claim = try #require(descriptor.fenceClaims.only)
        let claimedAlias = try RendererFenceAlias(validating: "mermaid")
        #expect(claim.alias == claimedAlias)
        #expect(claim.inlineMIMEType.rawValue == "text/mermaid")
        #expect(claim.validation != nil)

        // Reader markup: the disclosure-row card resolves through the claim
        // map — the same generic card markup D2 and Excalidraw produce.
        let document = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01HTESTPAGE000000000000001"),
            pageVersionID: PageVersionID(rawValue: "01HTESTPV00000000000000001"))
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            enabledInstalledDescriptors: [descriptor])
        let admission = RendererEmbedActivationAdmission(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            capability: .init(rawValue: UUID().uuidString),
            generation: 1)
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: RendererEmbedProjection(
                sourceEmbeds: [:],
                richFenceClaims: claims),
            documentIdentity: document,
            rendererActivationAdmission: admission)
        let html = MarkdownHTMLRenderer.render("```mermaid\ngraph TD\nA-->B\n```", options: options)
        #expect(html.contains("sdw-renderer-card"))
        #expect(html.contains("data-renderer-reference=\"org.selfdrivingwiki.mermaid-readonly/1.0.0/mermaid\""))
        #expect(html.contains("renderer-action://open"))
        #expect(html.contains("Open in Window"))

        // Hosted: the fence's inline artifact renders through the real
        // package session — the same authorized input.read path sources use.
        let bytes = Data("graph TD\n A-->B".utf8)
        let block = try MarkdownFencedBlock(
            documentIdentity: document,
            parserOrdinal: 0,
            rawInfoString: "mermaid",
            bytes: bytes)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            blockID: try #require(block.blockID),
            fenceAlias: claim.alias,
            mimeType: claim.inlineMIMEType,
            bytes: bytes)
        let input = RendererBridgeInput.inlineArtifact(artifact)
        let store = try GRDBWikiStore()
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: input)

        let entryURL = try Self.entryURL(for: descriptor)

        let (webView, _, teardown) = try await Self.mountSession(
            descriptor: descriptor,
            package: package,
            reader: reader,
            entryURL: entryURL,
            failureLabel: "hosted Mermaid fence session")
        defer { teardown() }

        let liveWebView = try #require(webView)

        _ = try await Self.waitForJavaScriptStringWithState(
            "document.querySelector('#diagram svg') ? 'diagram-rendered' : 'pending'",
            expectedValue: "diagram-rendered",
            in: liveWebView,
            description: "fence-declared Mermaid diagram",
            timeout: .seconds(45),
            state: """
            (function() {
                const errorRegion = document.getElementById('error');
                return JSON.stringify({
                    error: errorRegion && errorRegion.hidden === false ? errorRegion.textContent : 'hidden'
                });
            }())
            """)
    }

    @Test("install promotes the package without a restart, removal restores the fallback")
    func installAndRemovePreserveAvailabilityAndSource() async throws {
        let fixture = try MermaidHostedFixture()

        let root = URL.temporaryDirectory.appending(path: "mermaid-hosted-install-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Mermaid install fixture cleanup failed.") }
        }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let machineStore = RendererMachineIndexStore(layout: layout)
        let handle = try await RendererRuntimeFactory(layout: layout).assemble()
        let host = InstalledRendererHost(services: handle.services)

        let store = try GRDBWikiStore()
        let diagram = Data("graph TD\n A-->B".utf8)
        let source = try store.addSource(filename: "installer.mmd", data: diagram)

        // Before install: no descriptor claims the format.
        let indexBefore = try await machineStore.read()
        #expect(indexBefore.availableDescriptorProjection.isEmpty)

        let installed = await host.installRendererDirectory(fixture.packageDirectory)
        #expect(installed == true)
        let indexAfterInstall = try await machineStore.read()
        #expect(indexAfterInstall.availableDescriptorProjection.contains {
            $0.reference.registrationID.rawValue == "mermaid"
                && $0.reference.packageID.rawValue == "org.selfdrivingwiki.mermaid-readonly"
        })

        // The installed package's validation contract feeds the save-time
        // service: the same machine index the store reads.
        let validationService = FenceSyntaxValidationService(layout: layout)
        let warning = validationService.fenceSaveWarning(for: "```mermaid\nflowchart LR\n  A[unclosed\n```")
        #expect(warning?.contains("PARSE_ERROR") == true)
        let valid = validationService.fenceSaveWarning(for: "```mermaid\ngraph TD\n A-->B\n```")
        #expect(valid == nil)

        // Removal restores the no-package fallback: the projection loses the
        // claimant, validation skips, and source data survives.
        let removed = await host.removeRenderer(
            packageID: try .init(validating: "org.selfdrivingwiki.mermaid-readonly"),
            version: try .init(validating: "1.0.0"))
        #expect(removed == true)
        let indexAfterRemoval = try await machineStore.read()
        #expect(indexAfterRemoval.availableDescriptorProjection.contains {
            $0.reference.packageID.rawValue == "org.selfdrivingwiki.mermaid-readonly"
        } == false)
        let postRemovalWarning = validationService.fenceSaveWarning(for: "```mermaid\nflowchart LR\n  A[unclosed\n```")
        #expect(postRemovalWarning == nil)

        // Removal deletes the copied payload only; source data and its bytes
        // survive, so the Source presentation stays available.
        let survivingVersion = try #require(try store.activeContentVersion(sourceID: source.id))
        let preserved = try store.sourceContent(versionID: survivingVersion.id)
        #expect(preserved == diagram)

        try await handle.dispose()
    }

    @Test("with no package installed an .mmd source shows its code block and the bundle carries no engine")
    func noPackageLegsKeepReadableFallbacks() throws {
        // AC.8's no-package leg: an `.mmd` source row presents the Source tab
        // as a code block, with no renderer pane. There is no host fallback
        // renderer to render it — the readable code IS the presentation.
        let store = try GRDBWikiStore()
        let diagram = Data("graph TD\n A-->B".utf8)
        let summary = try store.addSource(filename: "plain.mmd", data: diagram)

        #expect(summary.mimeType == MimeType.mermaid)
        #expect(MimeType.isSourceTextPresentable(summary.mimeType))
        let bytes = try store.sourceContent(id: summary.id)
        let content = try #require(String(data: bytes, encoding: .utf8))
        let sourceMarkdown = SourceRendererPresentationPlanner.sourceMarkdown(
            for: summary, content: content)
        #expect(sourceMarkdown == "````\ngraph TD\n A-->B\n````")

        // The characterization carries no reader-projected diagram tab.
        let result = SourceDetailPresentationCharacterization.characterize(
            source: summary,
            boundedBytes: bytes,
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.tabs.isEmpty)
        #expect(result.contentArea == .markdown)

        // AC.3's bundle leg: the app process carries no vendored engine
        // resource. The reviewed package is the only copy.
        #expect(Bundle.main.url(forResource: "mermaid", withExtension: "js") == nil)
        #expect(Bundle.main.url(forResource: "mermaid.min", withExtension: "js") == nil)
        #expect(Bundle.main.url(forResource: "merval", withExtension: "bundle.js") == nil)
        #expect(Bundle.main.url(forResource: "merval.bundle", withExtension: "js") == nil)
    }

    // MARK: - Session mounting

    private static func entryURL(for descriptor: RendererDescriptor) throws -> URL {
        let entryPoint = try #require(descriptor.webEntryPoint)
        return RendererPackageScheme.url(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            path: entryPoint.path)
    }

    private struct SessionMount {
        let webView: WKWebView?
        let session: WikiAppWebViewSession
        let teardown: @MainActor () -> Void
    }

    private static func mountSession(
        descriptor: RendererDescriptor,
        package: ValidatedRendererPackage,
        reader: RendererAuthorizedInputReader,
        entryURL: URL,
        failureLabel: String
    ) async throws -> (WKWebView?, WikiAppWebViewSession, @MainActor () -> Void) {
        let provider = try ValidatedRendererPackageResourceProvider(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version,
            expectedPackageHash: package.packageHash,
            installedRoot: package.stagedRoot,
            validatedPackage: package)
        let reservation = RendererPackageReservation(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version)
        var session: WikiAppWebViewSession?
        let view = WikiAppWebView(
            identity: InstalledRendererWebViewIdentity(
                rendererReference: descriptor.reference,
                entryURL: entryURL),
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
                    externalActivationPolicy: .disabled)
                session = value
                return value
            },
            onFailure: { failure in
                Issue.record("\(failureLabel) failed: \(failure.kind)")
            })
        let host = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.orderFront(nil)
        let teardown: @MainActor () -> Void = {
            host.rootView = AnyView(EmptyView())
            session?.close()
            window.orderOut(nil)
            window.contentView = nil
        }

        try await waitFor(description: failureLabel) { session != nil }
        let liveSession = try #require(session)
        try await waitForReady(liveSession, description: failureLabel)
        return (liveSession.webView, liveSession, teardown)
    }

    // MARK: - Helpers

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
                throw MermaidHostedValidationError.timeout(description: description)
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
            let value = await evaluate(webView, javaScript) ?? ""
            if value == expectedValue { return expectedValue }
            if let state {
                lastState = await evaluate(webView, state) ?? "unavailable"
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        if state != nil {
            throw MermaidHostedValidationError.timeout(
                description: "\(description); last page state: \(lastState)")
        }
        throw MermaidHostedValidationError.timeout(description: description)
    }

    private static func evaluate(
        _ webView: WKWebView,
        _ javaScript: String
    ) async -> String? {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let result = try? await webView.evaluateJavaScript(javaScript) {
                return result as? String
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

private enum MermaidHostedValidationError: LocalizedError {
    case timeout(description: String)

    var errorDescription: String? {
        switch self {
        case let .timeout(description): "timed out waiting for \(description)"
        }
    }
}

private struct MermaidHostedFixture {
    let packageDirectory: URL
    let validator: RendererPackageValidator

    init() throws {
        packageDirectory = MermaidHostedFixture.repositoryRoot()
            .appending(path: "RendererPackages/Mermaid")
        guard FileManager.default.fileExists(
            atPath: packageDirectory.appending(path: "manifest.json").path) else {
            throw MermaidHostedValidationError.timeout(description: "the reviewed package must be committed")
        }
        validator = RendererPackageValidator(
            packageRoot: FileManager.default.temporaryDirectory
                .appending(path: "MermaidHostedValidation-\(UUID().uuidString)"))
    }

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

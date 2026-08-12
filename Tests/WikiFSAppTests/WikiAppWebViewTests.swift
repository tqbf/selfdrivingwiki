#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import WikiFSCore
@testable import WikiFS

@Suite("WikiAppWebView lifecycle")
@MainActor
struct WikiAppWebViewTests {
    @Test("mount defers session start until after the representable update")
    func mountDefersSessionStart() throws {
        let scheduler = ManualMainActorScheduler()
        let session = RecordingWebViewSession()
        let coordinator = WikiAppWebViewRepresentable.Coordinator(
            makeSession: { _, _ in session },
            schedule: scheduler.schedule)

        let container = NSView()
        coordinator.reconcile(identity: try identity("one"), in: container)

        #expect(session.events.isEmpty)
        #expect(container.subviews.first === session.hostedView)
        scheduler.runAll()
        #expect(session.events == [.started])
    }

    @Test("identity replacement closes the old session before starting its replacement")
    func identityReplacementClosesBeforeStartingReplacement() throws {
        let scheduler = ManualMainActorScheduler()
        let events = EventLog()
        let first = RecordingWebViewSession(events: events)
        let second = RecordingWebViewSession(events: events)
        var sessions = [first, second]
        let coordinator = WikiAppWebViewRepresentable.Coordinator(
            makeSession: { _, _ in sessions.removeFirst() },
            schedule: scheduler.schedule)
        let container = NSView()

        coordinator.reconcile(identity: try identity("one"), in: container)
        scheduler.runAll()
        coordinator.reconcile(identity: try identity("two"), in: container)

        #expect(events.values == [.started, .closed])
        scheduler.runAll()
        #expect(events.values == [.started, .closed, .started])
    }

    @Test("dismantle closes the mounted session and removes its view")
    func dismantleClosesSession() throws {
        let scheduler = ManualMainActorScheduler()
        let session = RecordingWebViewSession()
        let coordinator = WikiAppWebViewRepresentable.Coordinator(
            makeSession: { _, _ in session },
            schedule: scheduler.schedule)
        let container = NSView()

        coordinator.reconcile(identity: try identity("one"), in: container)
        scheduler.runAll()
        coordinator.teardown(from: container)

        #expect(session.events == [.started, .closed])
        #expect(container.subviews.isEmpty)
    }

    @Test("session callbacks defer SwiftUI-facing failure work")
    func sessionFailureDefersStateMutation() throws {
        let scheduler = ManualMainActorScheduler()
        let session = RecordingWebViewSession()
        var fallbackCount = 0
        let coordinator = WikiAppWebViewRepresentable.Coordinator(
            makeSession: { _, failure in
                session.failure = failure
                return session
            },
            onFailure: { _ in fallbackCount += 1 },
            schedule: scheduler.schedule)
        let container = NSView()

        coordinator.reconcile(identity: try identity("one"), in: container)
        session.fail()

        #expect(fallbackCount == 0)
        scheduler.runAll()
        #expect(fallbackCount == 1)
    }

    @Test("an unavailable installed renderer leaves the host's Source fallback available")
    func unavailableInstalledRendererReturnsNoView() throws {
        let descriptor = try installedDescriptor()
        let factory = InstalledRendererFactory.unavailable

        #expect(factory.makeView(for: descriptor, inputs: .unavailable, inputReader: nil, onFailure: { _ in }) == nil)
    }

    @Test("a bridge-oversized pinned input preserves Source fallback before a session starts")
    func oversizedPinnedInputReturnsNoView() throws {
        let store = try GRDBWikiStore()
        let source = try store.addSource(
            filename: "input.txt",
            data: Data(repeating: 0x61, count: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1))
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))
        let descriptor = try installedDescriptor(
            maximumInputByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1)
        let configuration = try installedConfiguration(for: descriptor)
        let factory = InstalledRendererFactory(makeSession: { _, _, _ in
            Issue.record("an oversized input must not create a renderer session")
            return RecordingWebViewSession()
        })
        let inputs = InstalledRendererFactory.Inputs(
            enabledDescriptors: [descriptor],
            resolveConfiguration: { _, _ in configuration })

        #expect(factory.makeView(
            for: descriptor,
            inputs: inputs,
            inputReader: reader,
            onFailure: { _ in }) == nil)
    }

    @Test("a below-cap pinned input admits the installed renderer before session start")
    func belowCapPinnedInputReturnsView() throws {
        let ceiling = WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
        let descriptor = try installedDescriptor(maximumInputByteCount: ceiling - 1)
        let configuration = try installedConfiguration(for: descriptor)
        let input = RendererBridgeInput.source(versionID: .init(rawValue: "version-1"))
        let reader = RendererAuthorizedInputReader(
            authorizedInput: input,
            inputByteCount: { requested in
                #expect(requested == input)
                return ceiling - 1
            },
            readPayload: { requested in
                #expect(requested == input)
                return .init(
                    mimeType: "text/plain",
                    bytes: Data(repeating: 0x61, count: ceiling - 1))
            }
        )
        let factory = InstalledRendererFactory(makeSession: { _, _, _ in
            Issue.record("a below-cap input should admit the installed renderer and create a session")
            return RecordingWebViewSession()
        })
        let inputs = InstalledRendererFactory.Inputs(
            enabledDescriptors: [descriptor],
            resolveConfiguration: { _, _ in configuration })

        #expect(factory.makeView(
            for: descriptor,
            inputs: inputs,
            inputReader: reader,
            onFailure: { _ in }) != nil)
    }

    @Test("reader teardown clears host-owned handlers without a SwiftUI state write")
    func readerTeardownClearsHandlers() {
        let coordinator = WikiReaderRep.Coordinator()
        let webView = WikiReaderWebView()
        webView.addURLHandler = { _ in }
        webView.addBookmarkHandler = { _ in }
        webView.onRendererActivation = { _, _ in }
        coordinator.webView = webView

        coordinator.teardown()

        #expect(webView.addURLHandler == nil)
        #expect(webView.addBookmarkHandler == nil)
        #expect(webView.onRendererActivation == nil)
        #expect(webView.rendererActivationAdmission == nil)
    }

    @Test("factory binds the pinned input, trusted links, and failure recorder to one hosted session")
    func factoryWiresPinnedInputAndLifecycleContracts() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = NSApplication.shared
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "input.txt", data: Data("ok".utf8))
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let reader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))
        let descriptor = try installedDescriptor(
            maximumInputByteCount: 1_024,
            linkPolicy: .userActivatedExternal)
        let failureRecorder: RendererSessionFailureRecording = { _, _ in }
        let configuration = try installedConfiguration(
            for: descriptor,
            failureRecorder: failureRecorder)
        var capturedConfiguration: InstalledRendererSessionConfiguration?
        let session = RecordingWebViewSession()
        let factory = InstalledRendererFactory(makeSession: { _, reportFailure, configuration in
            capturedConfiguration = configuration
            session.failure = reportFailure
            return session
        })
        let inputs = InstalledRendererFactory.Inputs(
            enabledDescriptors: [descriptor],
            resolveConfiguration: { _, _ in configuration })
        guard let view = factory.makeView(
            for: descriptor,
            inputs: inputs,
            inputReader: reader,
            onFailure: { _ in }) else {
            Issue.record("a valid pinned input should create an installed renderer view")
            return
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0 ..< 20 where capturedConfiguration == nil {
            await Task.yield()
        }
        let captured = try #require(capturedConfiguration)
        #expect(captured.inputReader?.authorizedInput == reader.authorizedInput)
        #expect(captured.externalActivationPolicy == .enabled)
        #expect(captured.failureRecorder != nil)
        for _ in 0 ..< 20 where session.events.isEmpty {
            await Task.yield()
        }
        #expect(session.events == [.started])

        hosting.rootView = AnyView(EmptyView())
        for _ in 0 ..< 20 where session.events.count < 2 {
            await Task.yield()
        }
        #expect(session.events == [.started, .closed])
    }

    @Test("Source detail dispatches installed renderers through the peer factory")
    func sourceDetailKeepsInstalledFactoryOutsideBuiltInMap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Sources/SourceDetailView.swift"),
            encoding: .utf8)

        #expect(source.contains("BuiltInRendererFactoryMap.makeView"))
        #expect(source.contains("installedRendererFactory.makeView"))
        #expect(source.contains("rendererAuthorizedInputReader(for: file.id)"))
        #expect(source.contains("failedInstalledRendererReference"))
    }

    @Test("source detail keeps renderer activation typed and inert without document identity")
    func sourceDetailGuardsMissingIdentityBeforeActivation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Sources/SourceDetailView.swift"),
            encoding: .utf8)

        #expect(source.contains("guard headVersion != nil else"))
        #expect(source.contains("onRendererActivation: headVersion == nil ? nil : activateRendererPane(reference:input:)"))
    }

    @Test("page detail threads the optional renderer sink through the existing reader host")
    func pageDetailThreadsOptionalRendererSink() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Pages/PageDetailView.swift"),
            encoding: .utf8)

        #expect(page.contains("let onRendererActivation"))
        #expect(page.contains("onRendererActivation: onRendererActivation"))
    }

    @Test("hosted SwiftUI mount exposes the session WebView and tears it down")
    func hostedMountAndDismantle() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = NSApplication.shared
        let webView = WKWebView()
        let session = RecordingWebViewSession(hostedView: webView)
        let view = WikiAppWebView(
            identity: try identity("hosted"),
            makeSession: { _, _ in session },
            onFailure: { _ in })
        let hosting = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(contentViewController: hosting)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0 ..< 20 where session.events.isEmpty {
            await Task.yield()
        }
        #expect(session.events == [.started])
        #expect(findWebView(in: hosting.view) === webView)

        hosting.rootView = AnyView(EmptyView())
        for _ in 0 ..< 20 where session.events.count < 2 {
            await Task.yield()
        }
        #expect(session.events == [.started, .closed])
    }

    private func identity(_ name: String) throws -> InstalledRendererWebViewIdentity {
        let packageID = try RendererPackageID(validating: "org.example.host")
        let version = try RendererPackageVersion(validating: "1.0.0")
        let registrationID = try RendererRegistrationID(validating: name)
        let entryURL = try #require(URL(string: "renderer-package://package/org.example.host/1.0.0/index.html"))
        return .init(
            rendererReference: .init(
                packageID: packageID,
                version: version,
                registrationID: registrationID),
            entryURL: entryURL)
    }
}

@MainActor
private final class ManualMainActorScheduler {
    private var operations: [@MainActor () -> Void] = []

    func schedule(_ operation: @escaping @MainActor () -> Void) {
        operations.append(operation)
    }

    func runAll() {
        while operations.isEmpty == false {
            operations.removeFirst()()
        }
    }
}

@MainActor
private final class EventLog {
    var values: [RecordingWebViewSession.Event] = []
}

@MainActor
private final class RecordingWebViewSession: WikiAppWebViewSessionControlling {
    enum Event: Equatable { case started, closed }

    let hostedView: NSView?
    private let eventLog: EventLog?
    var events: [Event] { eventLog?.values ?? localEvents }
    private var localEvents: [Event] = []
    var failure: (@MainActor (RendererSessionFailure) -> Void)?

    init(events: EventLog? = nil, hostedView: NSView = NSView()) {
        eventLog = events
        self.hostedView = hostedView
    }

    func start() { append(.started) }
    func close() { append(.closed) }
    func fail() {
        failure?(.init(
            sessionID: .init(rawValue: UUID()),
            kind: .navigationFailed))
    }

    private func append(_ event: Event) {
        if let eventLog { eventLog.values.append(event) }
        else { localEvents.append(event) }
    }
}

@MainActor
private func findWebView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView { return webView }
    for subview in view.subviews {
        if let webView = findWebView(in: subview) { return webView }
    }
    return nil
}

private func installedDescriptor(
    maximumInputByteCount: Int = 1,
    linkPolicy: RendererLinkPolicy = .none
) throws -> RendererDescriptor {
    let packageID = try RendererPackageID(validating: "org.example.installed")
    let version = try RendererPackageVersion(validating: "1.0.0")
    let registrationID = try RendererRegistrationID(validating: "installed")
    let path = try RendererRelativePath(validating: "index.html")
    return try RendererDescriptor(
        reference: .init(packageID: packageID, version: version, registrationID: registrationID),
        displayName: "Installed",
        implementation: .webPackage(.init(path: path)),
        matchers: [.artifactKind(.source)],
        presentations: [.web],
        approvedAssets: [.init(path: path, digest: RendererSHA256Digest(bytes: Array(repeating: 0, count: RendererSHA256Digest.byteCount)))],
        capabilities: linkPolicy == .userActivatedExternal ? [.inputRead, .externalLink] : [.inputRead],
        sizeLimits: try .init(
            maximumInputByteCount: maximumInputByteCount,
            maximumDecodedByteCount: maximumInputByteCount),
        linkPolicy: linkPolicy,
        accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
        compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
        priority: 0)
}

@MainActor
private func installedConfiguration(
    for descriptor: RendererDescriptor,
    resourceProvider: any RendererPackageResourceProviding = UnavailableRendererPackageResourceProvider(),
    failureRecorder: RendererSessionFailureRecording? = nil
) throws -> InstalledRendererSessionConfiguration {
    guard case let .webPackage(entryPoint) = descriptor.implementation else {
        throw RendererPackageResourceError.invalidRequest
    }
    let reservation = RendererPackageReservation(
        packageID: descriptor.reference.packageID,
        version: descriptor.reference.version)
    return .init(
        identity: .init(
            rendererReference: descriptor.reference,
            entryURL: RendererPackageScheme.url(
                packageID: reservation.packageID,
                version: reservation.version,
                path: entryPoint.path)),
        reservation: reservation,
        resourceProvider: resourceProvider,
        failureRecorder: failureRecorder,
        inputReader: nil,
        externalActivationPolicy: .disabled)
}

private struct UnavailableRendererPackageResourceProvider: RendererPackageResourceProviding {
    func resource(for url: URL) throws -> RendererPackageResource {
        throw RendererPackageResourceError.undeclaredAsset
    }
}

#endif

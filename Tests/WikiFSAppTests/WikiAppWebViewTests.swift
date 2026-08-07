#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
import WikiFSCore
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

        #expect(events.values == [.started])
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

        #expect(factory.makeView(for: descriptor, inputs: .unavailable, onFailure: { _ in }) == nil)
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
        #expect(source.contains("failedInstalledRendererReference"))
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
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0 ..< 20 where session.events.isEmpty {
            await Task.yield()
        }
        #expect(session.events == [.started])
        #expect(findWebView(in: hosting.view) === webView)

        hosting.rootView = EmptyView()
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

private func installedDescriptor() throws -> RendererDescriptor {
    let packageID = try RendererPackageID(validating: "org.example.installed")
    let version = try RendererPackageVersion(validating: "1.0.0")
    let registrationID = try RendererRegistrationID(validating: "installed")
    let path = try RendererRelativePath(validating: "index.html")
    return try RendererDescriptor(
        reference: .init(packageID: packageID, version: version, registrationID: registrationID),
        displayName: "Installed",
        implementation: .webPackage(.init(path: path)),
        matchers: [.init(mimeType: try RendererMIMEType(validating: "application/x-installed"))],
        presentations: [.web],
        approvedAssets: [.init(path: path, digest: try RendererSHA256Digest(validating: String(repeating: "0", count: 64)))],
        capabilities: [.inputRead],
        sizeLimits: .init(maximumInputBytes: 1, maximumAssetBytes: 1),
        linkPolicy: .none,
        accessibility: .init(label: "Installed", role: .document),
        compatibility: .init(minimumHostProtocolRevision: 1, maximumHostProtocolRevision: 1),
        priority: 0)
}
#endif

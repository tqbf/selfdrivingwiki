#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell

/// The minimal lifecycle surface that the SwiftUI host needs from one WebKit
/// session. Keeping this narrow lets the host test ordering without a live
/// renderer document.
@MainActor
protocol WikiAppWebViewSessionControlling: AnyObject {
    var hostedView: NSView? { get }
    func start()
    func close()
}

/// Exact identity for the WebKit resources that display one installed renderer.
/// A registration or version change is a new WebKit session, even if the entry
/// URL happens to have the same text.
struct InstalledRendererWebViewIdentity: Hashable {
    let rendererReference: RendererReference
    let entryURL: URL
}

/// SwiftUI entry point for one installed renderer's isolated WebKit session.
struct WikiAppWebView: View {
    let identity: InstalledRendererWebViewIdentity
    let makeSession: WikiAppWebViewRepresentable.SessionFactory
    let onFailure: @MainActor (RendererSessionFailure) -> Void

    var body: some View {
        WikiAppWebViewRepresentable(
            identity: identity,
            makeSession: makeSession,
            onFailure: onFailure)
    }
}

/// AppKit host for an installed renderer WebView. It owns no SwiftUI state:
/// session creation, callbacks, and teardown all stay in the coordinator.
struct WikiAppWebViewRepresentable: NSViewRepresentable {
    typealias NSViewType = NSView
    typealias SessionFactory = @MainActor (
        InstalledRendererWebViewIdentity,
        @escaping @MainActor (RendererSessionFailure) -> Void
    ) -> any WikiAppWebViewSessionControlling
    typealias MainActorScheduler = @MainActor (@escaping @MainActor () -> Void) -> Void

    let identity: InstalledRendererWebViewIdentity
    let makeSession: SessionFactory
    let onFailure: @MainActor (RendererSessionFailure) -> Void
    let schedule: MainActorScheduler

    init(
        identity: InstalledRendererWebViewIdentity,
        makeSession: @escaping SessionFactory,
        onFailure: @escaping @MainActor (RendererSessionFailure) -> Void,
        schedule: @escaping MainActorScheduler = Self.deferToNextMainActorTurn
    ) {
        self.identity = identity
        self.makeSession = makeSession
        self.onFailure = onFailure
        self.schedule = schedule
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(makeSession: makeSession, onFailure: onFailure, schedule: schedule)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.reconcile(identity: identity, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.reconcile(identity: identity, in: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.teardown(from: container)
    }

    private static func deferToNextMainActorTurn(_ operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in operation() }
    }

    @MainActor
    final class Coordinator {
        private let makeSession: SessionFactory
        private let onFailure: @MainActor (RendererSessionFailure) -> Void
        private let schedule: MainActorScheduler
        private var identity: InstalledRendererWebViewIdentity?
        private var session: (any WikiAppWebViewSessionControlling)?

        init(
            makeSession: @escaping SessionFactory,
            onFailure: @escaping @MainActor (RendererSessionFailure) -> Void = { _ in },
            schedule: @escaping MainActorScheduler = WikiAppWebViewRepresentable.deferToNextMainActorTurn
        ) {
            self.makeSession = makeSession
            self.onFailure = onFailure
            self.schedule = schedule
        }

        func reconcile(identity nextIdentity: InstalledRendererWebViewIdentity, in container: NSView) {
            guard identity != nextIdentity else { return }
            closeCurrentSession(from: container)

            let session = makeSession(nextIdentity) { [weak self] failure in
                // WebKit delegates can call back during an AppKit setter or a
                // SwiftUI update. Queue the view-facing work to avoid changing
                // SwiftUI state within that update transaction.
                self?.schedule { [weak self] in self?.onFailure(failure) }
            }
            identity = nextIdentity
            self.session = session
            if let hostedView = session.hostedView {
                hostedView.frame = container.bounds
                hostedView.autoresizingMask = [.width, .height]
                container.addSubview(hostedView)
            }
            schedule { [weak self, weak session] in
                guard let self, let session, self.session === session else { return }
                session.start()
            }
        }

        func teardown(from container: NSView) {
            closeCurrentSession(from: container)
        }

        private func closeCurrentSession(from container: NSView) {
            guard let session else { return }
            // Close before detaching so WebKit delegates and scheme tasks lose
            // their resources before the replacement can start.
            session.close()
            session.hostedView?.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            self.session = nil
            identity = nil
        }
    }
}

extension WikiAppWebViewSession: WikiAppWebViewSessionControlling {
    var hostedView: NSView? { webView }
}
#endif

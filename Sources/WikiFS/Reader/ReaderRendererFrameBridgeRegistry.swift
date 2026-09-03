#if os(macOS)
import Foundation
import WikiFSCore

// pattern: Imperative Shell — owns per-frame bridge sessions and their teardown.

/// One admitted frame's bridge session: the exact authorized readers and the
/// broker that answers its package-authored envelopes. Everything here was
/// already authorized during Markdown preparation; the registry only scopes
/// each session to its cryptographically opaque frame token and origin host.
@MainActor
final class ReaderRendererFrameSession {
    let placeholderID: RendererAttachmentPlaceholderID
    let frameToken: RendererFrameOriginToken
    let expectedOriginHost: String
    let rendererReference: RendererReference
    let generation: Int
    let broker: RendererContentWorldBroker
    /// The reader webview this session is bound to. Messages from other
    /// webviews are rejected (a compromised frame cannot hop webviews).
    let expectedWebViewID: ObjectIdentifier
    /// Load timeout handle: a frame that never finishes loading releases its
    /// session and records a failure.
    var loadTimeoutTask: Task<Void, Never>?
    private(set) var isClosed = false

    init(
        placeholderID: RendererAttachmentPlaceholderID,
        frameToken: RendererFrameOriginToken,
        rendererReference: RendererReference,
        generation: Int,
        broker: RendererContentWorldBroker,
        expectedWebViewID: ObjectIdentifier
    ) {
        self.placeholderID = placeholderID
        self.frameToken = frameToken
        self.expectedOriginHost = frameToken.rawValue
        self.rendererReference = rendererReference
        self.generation = generation
        self.broker = broker
        self.expectedWebViewID = expectedWebViewID
    }

    /// Closes the broker and cancels the load timeout. Idempotent.
    func close() {
        guard isClosed == false else { return }
        isClosed = true
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        broker.close()
    }
}

/// The document-scoped registry of admitted package frames. Keyed by frame
/// token; every lookup re-verifies origin host, webview identity, and
/// generation so a stale, replayed, or cross-frame message fails closed.
///
/// Resource policy: no more admitted package frames than
/// `ReaderDOMRendererBudget.maximumPackageFrames`; each frame has a load
/// timeout; and collapse / DOM removal / navigation / dismantle / revocation
/// deterministically close exactly the intended session.
@MainActor
final class ReaderRendererFrameBridgeRegistry {
    private var sessions: [RendererFrameOriginToken: ReaderRendererFrameSession] = [:]
    /// Reverse index: placeholder → token, for scoped collapse/removal.
    private var tokensByPlaceholder: [RendererAttachmentPlaceholderID: RendererFrameOriginToken] = [:]
    private let maximumFrames: Int
    private let loadTimeout: Duration
    /// Failure recorder wired by the reader (surfaces renderer failures).
    var onSessionFailure: (@MainActor (RendererAttachmentPlaceholderID, RendererSessionFailure) -> Void)?

    init(
        maximumFrames: Int = ReaderDOMRendererBudget.maximumPackageFrames,
        loadTimeout: Duration = ReaderDOMRendererBudget.frameLoadTimeout
    ) {
        self.maximumFrames = max(0, maximumFrames)
        self.loadTimeout = loadTimeout
    }

    var activeSessionCount: Int { sessions.count }

    func session(for token: RendererFrameOriginToken) -> ReaderRendererFrameSession? {
        sessions[token]
    }

    func token(for placeholderID: RendererAttachmentPlaceholderID) -> RendererFrameOriginToken? {
        tokensByPlaceholder[placeholderID]
    }

    /// Admits one frame session. Fails closed (nil) when the frame budget is
    /// exhausted or the placeholder already holds a live session.
    @discardableResult
    func admit(
        placeholderID: RendererAttachmentPlaceholderID,
        frameToken: RendererFrameOriginToken,
        rendererReference: RendererReference,
        generation: Int,
        broker: RendererContentWorldBroker,
        expectedWebViewID: ObjectIdentifier
    ) -> Bool {
        guard sessions[frameToken] == nil,
              tokensByPlaceholder[placeholderID] == nil,
              sessions.count < maximumFrames
        else { return false }
        let session = ReaderRendererFrameSession(
            placeholderID: placeholderID,
            frameToken: frameToken,
            rendererReference: rendererReference,
            generation: generation,
            broker: broker,
            expectedWebViewID: expectedWebViewID)
        sessions[frameToken] = session
        tokensByPlaceholder[placeholderID] = frameToken
        // Load timeout: a frame that never finishes releases its session and
        // records a failure against its placeholder (deterministic release).
        session.loadTimeoutTask = Task { [weak self] in
            // Cancellation is the expected path (frame loaded, session closed,
            // registry torn down); sleeping through it is not an error to log.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: self?.loadTimeout ?? .seconds(30))
            guard Task.isCancelled == false else { return }
            self?.timeoutFired(token: frameToken, generation: generation)
        }
        return true
    }

    /// Validates provenance and returns the session for one incoming message.
    /// Rejects unknown tokens, wrong origins, wrong webviews, and closed
    /// frames — the frame-scoped equivalent of the full-window session's
    /// provenance checks. The session's own admission generation is the
    /// authority; callers do not pass a generation.
    func authorize(
        token: RendererFrameOriginToken,
        originHost: String,
        originScheme: String,
        webViewID: ObjectIdentifier?
    ) -> ReaderRendererFrameSession? {
        guard let session = sessions[token],
              session.isClosed == false,
              session.expectedOriginHost == originHost,
              originScheme == RendererPackageScheme.name,
              session.expectedWebViewID == webViewID
        else { return nil }
        return session
    }

    /// The frame finished loading; cancels its timeout.
    func frameDidLoad(token: RendererFrameOriginToken) {
        sessions[token]?.loadTimeoutTask?.cancel()
        sessions[token]?.loadTimeoutTask = nil
    }

    /// Scoped collapse: closes exactly this placeholder's session. Other
    /// frames are untouched.
    func close(placeholderID: RendererAttachmentPlaceholderID) {
        guard let token = tokensByPlaceholder[placeholderID] else { return }
        sessions[token]?.close()
        sessions.removeValue(forKey: token)
        tokensByPlaceholder.removeValue(forKey: placeholderID)
    }

    /// Scoped DOM removal (same semantics as collapse, different caller).
    func remove(placeholderID: RendererAttachmentPlaceholderID) {
        close(placeholderID: placeholderID)
    }

    /// Document replacement / reader dismantle / snapshot replacement: close
    /// every session. Deterministic; no generation check (teardown always
    /// cleans up its own records).
    func closeAll() {
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
        tokensByPlaceholder.removeAll()
    }

    private func timeoutFired(token: RendererFrameOriginToken, generation: Int) {
        guard let session = sessions[token],
              session.isClosed == false,
              session.generation == generation
        else { return }
        DebugLog.reader("reader package frame load timeout for \(session.placeholderID.rawValue)")
        onSessionFailure?(
            session.placeholderID,
            .init(sessionID: .init(rawValue: UUID()), kind: .loadTimedOut))
        close(placeholderID: session.placeholderID)
    }
}
#endif

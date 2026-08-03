#if os(macOS)
import WikiFSTypes

/// Identifies which chat a `RemoteChatSession` mirrors.
///
/// Replaces a bare `String` plus the sentinel `"__wiki_draft_chat__"` that
/// stood in for the not-yet-persisted composer. That encoding had two failure
/// modes the type system now rules out:
///
/// * The sentinel shared a namespace with real chat ULIDs, so "is this the
///   draft?" was a string comparison against a magic constant that any call
///   site could forget (or misspell) — and a chat whose id happened to equal
///   the sentinel would have been silently treated as the draft.
/// * `activeChatID` returned that sentinel for a live draft, so the draft could
///   in principle satisfy a `activeChatID == chatID` liveness check. The
///   `.draft` case has no `ChatID` at all, so it cannot.
public enum ChatSessionKey: Hashable, Sendable {
    /// The `.newChat` composer — no persisted row exists yet. The daemon
    /// assigns a real id on the first send, at which point the tab retargets
    /// to `.chat(id)` and a fresh session is created under that key.
    case draft
    /// A persisted chat row.
    case chat(ChatID)

    /// The persisted chat id, or `nil` for the draft. The conversion point
    /// between this typed key and the `String` chat ids that cross XPC.
    public var chatID: ChatID? {
        switch self {
        case .draft: return nil
        case .chat(let id): return id
        }
    }

    /// The wire form (a chat ULID), or `nil` for the draft — which has no
    /// daemon-side session and so is never a valid XPC target.
    public var rawValue: String? { chatID?.rawValue }
}
#endif

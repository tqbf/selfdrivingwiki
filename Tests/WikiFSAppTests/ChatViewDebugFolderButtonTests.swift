#if os(macOS)
import Foundation
import Testing
import WikiFSEngine
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for `ChatDetailView.debugFolderButtonHelpText` (#671 / Bug 2) — the
/// "Reveal Debug Folder" button's help-text predicate.
///
/// Bug 2 context: the button was gated on (and therefore only visible when)
/// `launcher.debugFolderURL(forChat:) ?? launcher.debugFolderURL` returned
/// non-nil. That map (`chatLogPaths`) was in-memory and only populated at
/// spawn commit (`AgentLauncher.startInteractiveQuery`), so a persisted chat
/// reopened from history that ran in a *previous* app session had no entry —
/// the button never appeared, and the operator could not tell the feature
/// existed. The fix: ALWAYS render the button when there is a `chatID`, and
/// DISABLE it (with an explanatory tooltip) when no debug URL is available.
///
/// #681 follow-up: `debugFolderURL(forChat:)` is now a pure function of
/// chatID — it resolves `<Caches>/Self Driving Wiki-agent/<chatULID>/runs/<latest>/debug/`
/// from disk at read time. So the disabled state is no longer "this wasn't
/// run in this app session" (it can persist across restarts); the only
/// disabled-state case is "no `<chatULID>/runs/` directory on disk" — a chat
/// that has never spawn-committed (draft / preflight failure). The disabled-
/// state help text was updated to reflect this.
///
/// These tests pin the help-text contract (the text the operator sees in the
/// tooltip in each state) so the disabled-state explanation stays accurate
/// even if the trigger logic changes. Pure predicate tests — no SwiftUI view
/// tree required (following the `composerCaptionText` / `canSendPredicate` /
/// `preflightBannerMessage` pattern).
@Suite struct ChatViewDebugFolderButtonTests {

    // MARK: - Disabled-state help text (no debug URL)

    /// A chat that has never spawn-committed (no `<chatULID>/runs/` directory
    /// on disk — e.g. a draft chat or one whose preflight failed before scratch
    /// creation) hits the disabled state with an explanatory tooltip so the
    /// operator knows why AND that the feature exists at all (Bug 2).
    @Test func helpText_whenNoDebugURL_explainsNoRunsOnDisk() {
        #expect(ChatDetailView.debugFolderButtonHelpText(debugURL: nil) ==
            "No debug folder on disk for this chat")
    }

    // MARK: - Enabled-state help text (debug URL available)

    /// A live chat (or any chat with at least one spawn-committed run on disk)
    /// reveals the standard debug-folder tooltip — same copy the button had
    /// before Bug 2's fix, so enabled-state UX is unchanged.
    @Test func helpText_whenDebugURLPresent_describesTrace() {
        let url = URL(fileURLWithPath: "/tmp/some-chat/debug")
        #expect(ChatDetailView.debugFolderButtonHelpText(debugURL: url) ==
            "Open the complete debug trace folder (ACP messages, permissions, usage)")
    }

    /// Help-text contract: the enabled-state message stays identical for any
    /// non-nil URL (the path's content is irrelevant to the tooltip copy).
    /// Pins the message so a future copy-edit doesn't silently diverge from
    /// the Activity menu's Reveal Debug Folder tooltip (mirrors ingestion's
    /// `ActivityWindowView.revealMenu(for:)` per the #671 comment).
    @Test func helpText_isIdentical_forAnyNonNilURL() {
        let urlA = URL(fileURLWithPath: "/var/folders/xyz/01JAAA/debug")
        let urlB = URL(fileURLWithPath: "/Users/dev/Library/Group Containers/.../chat-id/debug")
        #expect(ChatDetailView.debugFolderButtonHelpText(debugURL: urlA) ==
            ChatDetailView.debugFolderButtonHelpText(debugURL: urlB))
    }

    /// Help-text contract: the two states return distinct copy (the disabled
    /// tooltip never leaks into the enabled state, and vice versa). A
    /// regression that returns the wrong text in either direction would
    /// surface here.
    @Test func helpText_disabledAndEnabledStates_areDifferent() {
        let url = URL(fileURLWithPath: "/tmp/debug")
        let disabled = ChatDetailView.debugFolderButtonHelpText(debugURL: nil)
        let enabled = ChatDetailView.debugFolderButtonHelpText(debugURL: url)
        #expect(disabled != enabled)
        #expect(!disabled.isEmpty)
        #expect(!enabled.isEmpty)
    }
}
#endif

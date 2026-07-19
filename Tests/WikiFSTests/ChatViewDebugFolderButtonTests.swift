import Foundation
import Testing
import WikiFSEngine
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for `ChatView.debugFolderButtonHelpText` (#671 / Bug 2) — the
/// "Reveal Debug Folder" button's help-text predicate.
///
/// Bug 2 context: the button was gated on (and therefore only visible when)
/// `launcher.debugFolderURL(forChat:) ?? launcher.debugFolderURL` returned
/// non-nil. That map (`chatLogPaths`) is in-memory and only populated at
/// spawn commit (`AgentLauncher.startInteractiveQuery`), so a persisted chat
/// reopened from history that ran in a *previous* app session had no entry —
/// the button never appeared, and the operator could not tell the feature
/// existed. The fix: ALWAYS render the button when there is a `chatID`, and
/// DISABLE it (with an explanatory tooltip) when no debug URL is available.
///
/// These tests pin the help-text contract (the text the operator sees in the
/// tooltip in each state) so the disabled-state explanation stays accurate
/// even if the trigger logic changes. Pure predicate tests — no SwiftUI view
/// tree required (following the `composerCaptionText` / `canSendPredicate` /
/// `preflightBannerMessage` pattern).
@Suite struct ChatViewDebugFolderButtonTests {

    // MARK: - Disabled-state help text (no debug URL)

    /// A persisted chat reopened from history that ran in a previous app
    /// session has no `chatLogPaths` entry — the button is rendered but
    /// disabled, with an explanatory tooltip so the operator knows why AND
    /// that the feature exists at all (Bug 2).
    @Test func helpText_whenNoDebugURL_explainsSessionOnly() {
        #expect(ChatView.debugFolderButtonHelpText(debugURL: nil) ==
            "Debug logs only available for chats run in this session")
    }

    // MARK: - Enabled-state help text (debug URL available)

    /// A live chat (or a chat that ran earlier this session and has an entry
    /// in `chatLogPaths`) reveals the standard debug-folder tooltip — same
    /// copy the button had before Bug 2's fix, so enabled-state UX is
    /// unchanged.
    @Test func helpText_whenDebugURLPresent_describesTrace() {
        let url = URL(fileURLWithPath: "/tmp/some-chat/debug")
        #expect(ChatView.debugFolderButtonHelpText(debugURL: url) ==
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
        #expect(ChatView.debugFolderButtonHelpText(debugURL: urlA) ==
            ChatView.debugFolderButtonHelpText(debugURL: urlB))
    }

    /// Help-text contract: the two states return distinct copy (the disabled
    /// tooltip never leaks into the enabled state, and vice versa). A
    /// regression that returns the wrong text in either direction would
    /// surface here.
    @Test func helpText_disabledAndEnabledStates_areDifferent() {
        let url = URL(fileURLWithPath: "/tmp/debug")
        let disabled = ChatView.debugFolderButtonHelpText(debugURL: nil)
        let enabled = ChatView.debugFolderButtonHelpText(debugURL: url)
        #expect(disabled != enabled)
        #expect(!disabled.isEmpty)
        #expect(!enabled.isEmpty)
    }
}

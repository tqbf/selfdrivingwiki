import AppKit
import WikiFSEngine

/// Application delegate that intercepts termination to show a "confirm to quit"
/// dialog, then flushes pending autosaves before the app actually exits.
///
/// Implements `applicationShouldTerminate(_:)` returning `.terminateLater` so the
/// system pauses termination while we present an `NSAlert`, then we call
/// `NSApp.reply(toApplicationShouldTerminate:)` with the user's choice. This
/// catches **all** termination paths: ⌘Q, Apple menu Quit, Dock Quit, and system
/// shutdown — not just the menu item.
///
/// Additionally implements `applicationShouldTerminateAfterLastWindowClosed(_:)`
/// returning `true`, so closing the final window — e.g. pressing ⌘W repeatedly
/// until no windows remain — routes through `applicationShouldTerminate`,
/// triggering the same confirmation dialog. This is the "⌘W too many times"
/// guardrail: the app won't silently vanish behind a flurry of window closes.
///
/// The confirmation can be toggled in Settings → General (key
/// `confirmBeforeQuitting`, default **on** so the feature works out of the box).
/// However, even when the setting is **off**, the app still asks for
/// confirmation if an extraction, ingestion, or agent operation is in flight —
/// silent termination during active work could lose data.
final class QuitConfirmationDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Injected dependencies

    /// Called before the app terminates so the model can flush buffered edits.
    /// Wired in `WikiFSApp.init` after the manager is created.
    var flushPendingSaves: (() -> Void)?

    /// Returns a human-readable description of any operation in flight (PDF
    /// extraction, source ingestion, or an agent run), or `nil` when the app
    /// is idle. The quit dialog message is tailored based on what's running.
    ///
    /// This covers operations that `isRunning` alone misses: `isExtracting`
    /// (the PDF→Markdown phase before the agent process spawns) and
    /// non-empty `ingestingSourceIDs` (an agent-phase ingest in progress).
    var activeOperationDescription: (() -> String?)?

    // MARK: - Settings key

    static let confirmQuitKey = "confirmBeforeQuitting"

    /// `@AppStorage` doesn't exist in this non-SwiftUI context, but the default
    /// is "ask" (true) when the key is unset — matching the feature's purpose.
    static var confirmBeforeQuitting: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: confirmQuitKey) != nil else { return true }
        return defaults.bool(forKey: confirmQuitKey)
    }

    // MARK: - Termination

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Flush pending saves regardless — don't lose buffered edits on quit.
        flushPendingSaves?()

        let activeOp = activeOperationDescription?()

        // If nothing is running AND the user has disabled confirm-before-quit,
        // quit now without a dialog.
        guard activeOp != nil || Self.confirmBeforeQuitting else {
            return .terminateNow
        }

        // Either the user wants confirmation, or there's active work we
        // shouldn't interrupt silently — show the dialog in both cases.
        let alert = NSAlert()
        alert.alertStyle = .warning

        if let description = activeOp {
            alert.messageText = "Quit Self Driving Wiki?"
            alert.informativeText =
                "\(description) is still running and will be cancelled. "
                + "Are you sure you want to quit?"
        } else {
            alert.messageText = "Quit Self Driving Wiki?"
            alert.informativeText = "Are you sure you want to quit?"
        }

        let quitButton = alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        quitButton.hasDestructiveAction = true
        quitButton.keyEquivalent = "\r"    // Return → default (Quit)
        // Make Cancel the escape-equivalent so ⎋ dismisses without quitting.
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        // Present as a sheet on the current key window when possible; fall back
        // to a modal dialog when no window is available (e.g. all windows
        // closed but app still active).
        if let window = sender.windows.first(
            where: { $0.isVisible && $0.canBecomeKey }
        ) {
            alert.beginSheetModal(for: window) { response in
                NSApp.reply(
                    toApplicationShouldTerminate:
                        response == .alertFirstButtonReturn
                )
            }
        } else {
            let response = alert.runModal()
            NSApp.reply(
                toApplicationShouldTerminate:
                    response == .alertFirstButtonReturn
            )
        }

        // We've deferred the decision to the alert callback.
        return .terminateLater
    }

    // MARK: - Last window closed

    /// Asking `true` here makes closing the **last** remaining window (⌘W, the
    /// close button, or the Window → Close menu item) route through
    /// `applicationShouldTerminate(_:)`. That's the path that presents the
    /// confirm-on-quit dialog — so "⌘W too many times" no longer silently
    /// dismisses the app.
    ///
    /// Returning `true` unconditionally (independent of the
    /// `confirmBeforeQuitting` setting) is deliberate: it only steers the
    /// *last*-window-close case into the termination flow; whether the user is
    /// actually asked, or the app quits immediately, is decided in
    /// `applicationShouldTerminate` based on the setting (and whether any work
    /// is in flight). With the setting off and nothing running, the last
    /// window close quits the app right away (no dialog); with it on, the
    /// dialog appears. If work is in flight, the dialog appears regardless.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        return true
    }
}

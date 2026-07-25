#if os(macOS)
import SwiftUI
import WikiCtlCore

/// A dismissible status banner that surfaces daemon connection state (#878).
///
/// - **Red** banner when `.disconnected`: "wikid daemon is not running — some
///   features may be unavailable." Dismissible with an X button; reappears on
///   the next disconnect.
///
/// The positive recovery signal (transition to `.connected` after a disconnect)
/// is NOT shown here — it surfaces as a small transient popover anchored to the
/// menu-bar status item, via `MenuBarItemController.showTransientHint` (same
/// treatment as "Ingest queued" / "Lint queued"). This view only owns the
/// persistent red banner that needs to stay up until dismissed.
///
/// Reads the `DaemonHealthMonitor` from the environment. When `nil` (no monitor
/// wired), no banner is shown.
struct DaemonStatusBanner: View {
    @Environment(\.daemonHealthMonitor) private var healthMonitor

    /// Whether the user has dismissed the current disconnect banner. Reset to
    /// `false` whenever the daemon reconnects so the NEXT disconnect shows the
    /// banner again.
    @State private var hasDismissedDisconnect = false

    /// Tracks the previous state to detect transitions.
    @State private var previousState: DaemonConnectionState?

    var body: some View {
        Group {
            if let healthMonitor, healthMonitor.state == .disconnected, !hasDismissedDisconnect {
                disconnectedBanner
            }
        }
        .animation(.easeInOut(duration: 0.2), value: healthMonitor?.state)
        .onChange(of: healthMonitor?.state) { _, newState in
            handleStateChange(to: newState)
        }
        .onAppear {
            previousState = healthMonitor?.state
        }
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text("wikid daemon is not running — some features may be unavailable.")
                .font(.callout)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button {
                hasDismissedDisconnect = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.9))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Handle a state transition. On disconnect, reset the dismiss flag so the
    /// banner shows. (The reconnect signal is handled by the menu-bar hint
    /// popover — see `MenuBarItemController`.)
    private func handleStateChange(to newState: DaemonConnectionState?) {
        guard let newState else { return }
        previousState = newState

        if newState == .disconnected {
            // New (or recurring) disconnect — reset the dismiss flag so the
            // red banner shows again.
            hasDismissedDisconnect = false
        }
    }
}
#endif

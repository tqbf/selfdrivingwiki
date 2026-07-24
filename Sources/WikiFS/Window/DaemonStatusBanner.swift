#if os(macOS)
import SwiftUI
import WikiCtlCore

/// A dismissible status banner that surfaces daemon connection state (#878).
///
/// - **Red** banner when `.disconnected`: "wikid daemon is not running — some
///   features may be unavailable." Dismissible with an X button; reappears on
///   the next disconnect.
/// - **Green** banner on recovery (transition to `.connected` after being
///   disconnected): "wikid daemon reconnected." Auto-dismisses after 3 seconds.
///
/// Reads the `DaemonHealthMonitor` from the environment. When `nil` (no monitor
/// wired), no banner is shown.
struct DaemonStatusBanner: View {
    @Environment(\.daemonHealthMonitor) private var healthMonitor

    /// Whether the user has dismissed the current disconnect banner. Reset to
    /// `false` whenever the daemon reconnects so the NEXT disconnect shows the
    /// banner again.
    @State private var hasDismissedDisconnect = false

    /// Whether the green "reconnected" banner is currently showing.
    @State private var showReconnectedBanner = false

    /// Tracks the previous state to detect transitions.
    @State private var previousState: DaemonConnectionState?

    var body: some View {
        Group {
            if let healthMonitor {
                bannerContent(for: healthMonitor.state)
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

    @ViewBuilder
    private func bannerContent(for state: DaemonConnectionState?) -> some View {
        if state == .disconnected, !hasDismissedDisconnect {
            disconnectedBanner
        } else if showReconnectedBanner {
            reconnectedBanner
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

    private var reconnectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text("wikid daemon reconnected.")
                .font(.callout)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.9))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Handle a state transition. On disconnect, reset the dismiss flag so the
    /// banner shows. On reconnect (from disconnected), show the green banner
    /// for 3 seconds.
    private func handleStateChange(to newState: DaemonConnectionState?) {
        guard let newState else { return }
        let oldState = previousState
        previousState = newState

        if newState == .disconnected {
            // New (or recurring) disconnect — reset the dismiss flag so the
            // red banner shows again.
            hasDismissedDisconnect = false
        }

        if newState == .connected, oldState == .disconnected || oldState == .reconnecting {
            // Recovery from a disconnected state — show the green banner and
            // auto-dismiss after 3 seconds.
            showReconnectedBanner = true
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeInOut(duration: 0.2)) {
                    showReconnectedBanner = false
                }
            }
        }
    }
}
#endif

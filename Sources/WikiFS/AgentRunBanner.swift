import SwiftUI
import WikiFSCore

/// The "Agent is …" status banner, shown at the top of the activity sidebar.
/// The status line is operation-aware: an ingest rewrites pages ("updating"),
/// but a query is read-only Q&A ("searching") and a lint is a read-only check —
/// so the wording matches what the agent is actually doing.
///
/// SWIFTUI-RULES §1.1: it is ALWAYS mounted and animates a DIMENSION (its height,
/// via `frame(height:)` + `clipped()`), never its presence — inserting/removing a
/// view with a transition inside hosted SwiftUI risks the constraint-engine crash.
/// Reduce Motion skips the animation entirely.
struct AgentRunBanner: View {
    let isVisible: Bool
    /// The operation currently in flight, used to pick the status line. `nil`
    /// (the default) falls back to a generic "working" message.
    var kind: WikiOperation.Kind? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(statusMessage)
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: isVisible ? Self.barHeight : 0)
        .frame(maxWidth: .infinity)
        .background(.yellow.opacity(0.18))
        .clipped()
        .accessibilityHidden(!isVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isVisible)
    }

    /// Operation-aware status line. Only an ingest actually rewrites the wiki; a
    /// query answers from it (read-only) and a lint inspects it.
    private var statusMessage: String {
        switch kind {
        case .ingest: "Agent is updating the wiki…"
        case .query: "Agent is searching your wiki…"
        case .lint: "Agent is checking your wiki…"
        case nil: "Agent is working…"
        }
    }

    private static let barHeight: CGFloat = 32
}

import SwiftUI
import WikiFSEngine

struct AgentRunStatusView: View {
    @Bindable var launcher: AgentLauncher
    let now: Date

    var body: some View {
        if launcher.isRunning, let startedAt = launcher.runStartedAt {
            HStack(spacing: 6) {
                Image(systemName: isQuiet ? "hourglass" : "waveform.path")
                    .font(.caption)
                    .foregroundStyle(isQuiet ? .orange : .secondary)
                    .frame(width: 14)
                Text(statusText(startedAt: startedAt))
                    .font(.caption)
                    .foregroundStyle(isQuiet ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityLabel(accessibilityText(startedAt: startedAt))
        }
    }

    private var isQuiet: Bool {
        guard let lastActivityAt = launcher.lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) >= Self.quietThreshold
    }

    private func statusText(startedAt: Date) -> String {
        let elapsed = durationString(now.timeIntervalSince(startedAt))
        let lastOutput = launcher.lastActivityAt.map { durationString(now.timeIntervalSince($0)) } ?? "unknown"
        let pid = launcher.currentProcessID.map { " · pid \($0)" } ?? ""
        if isQuiet {
            return "Still running · no output for \(lastOutput) · elapsed \(elapsed)\(pid)"
        }
        return "Running · last output \(lastOutput) ago · elapsed \(elapsed)\(pid)"
    }

    private func accessibilityText(startedAt: Date) -> String {
        statusText(startedAt: startedAt)
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    private static let quietThreshold: TimeInterval = 60
}

// pattern: Functional Core

import Foundation
import WikiFSCore

/// Immutable forensic context captured before a watchdog cancels a turn.
///
/// The artifact deliberately contains only renderable permission metadata: it
/// is safe to persist in the run's debug folder and to hand to a later retry.
struct CeilingKillContext: Codable, Sendable, Equatable {
    struct PendingPermission: Codable, Sendable, Equatable {
        let toolCallID: ToolCallID
        let toolName: String?
        let inputSummary: String?
        let requestedAt: Date
        let waitSeconds: TimeInterval
    }

    let occurredAt: Date
    let totalSeconds: TimeInterval
    let pendingPermissions: [PendingPermission]

    /// Short, bounded retry advisory. Returning nil preserves normal prompts
    /// when no prior ceiling kill recorded a pending permission.
    var retryAdvisory: String? {
        guard let pending = pendingPermissions.first else { return nil }
        let command = pending.inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let action: String
        if let command, !command.isEmpty {
            action = command
        } else {
            action = pending.toolName ?? "unknown tool"
        }
        return "Prior turn hit its ceiling after \(Self.duration(totalSeconds)) while permission for `\(action)` waited \(Self.duration(pending.waitSeconds)). Avoid repeating this permission-triggering pattern."
    }

    static func loadLatestPriorRun(in runsURL: URL, excluding scratchURL: URL) -> CeilingKillContext? {
        let manager = FileManager.default
        let children: [URL]
        do {
            children = try manager.contentsOfDirectory(
                at: runsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            DebugLog.agent("CeilingKillContext: failed to list \(runsURL.path): \(error.localizedDescription)")
            return nil
        }
        let artifact = children
            .filter { $0.standardizedFileURL != scratchURL.standardizedFileURL }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .lazy
            .map { $0.appendingPathComponent("debug/ceiling-kill-context.json") }
            .first { manager.fileExists(atPath: $0.path) }
        guard let artifact else { return nil }
        return load(from: artifact)
    }

    static func load(from artifact: URL) -> CeilingKillContext? {
        let data: Data
        do {
            data = try Data(contentsOf: artifact)
        } catch {
            DebugLog.agent("CeilingKillContext: failed to read \(artifact.path): \(error.localizedDescription)")
            return nil
        }
        do {
            return try JSONDecoder().decode(CeilingKillContext.self, from: data)
        } catch {
            DebugLog.agent("CeilingKillContext: failed to decode \(artifact.path): \(error.localizedDescription)")
            return nil
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let minutes = rounded / 60
        let remainder = rounded % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }
}

// Portable ACP-era value types used across the engine and queue system.
//
// These types originated in ACPBackend.swift / ACPPermissions.swift (macOS-only,
// guarded with #if os(macOS) for Linux portability — #754, #780). They are
// pure value types with no `ACP` product dependency (only `ACPModel` where
// needed, which IS portable), so they live here unguarded for Linux to use.

import Foundation
import ACPModel

// MARK: - SessionUsage

// `SessionUsage` was extracted from ACPBackend.swift so the queue system
// (QueueEngine, QueueWorker, QueueIngestionProvider, etc.) compiles on Linux
// without the macOS-only `ACP` product dependency.

/// Cumulative token/cost usage for a session. Populated by `ACPBackend` from
/// ACP `Usage` / `UsageUpdate` events; emitted to the queue system and UI.
public struct SessionUsage: Sendable, Codable {
    /// Cumulative input tokens across all turns (from `Usage.inputTokens`).
    public let inputTokens: Int
    /// Cumulative output tokens across all turns (from `Usage.outputTokens`).
    public let outputTokens: Int
    /// Cumulative total tokens (from `Usage.totalTokens`).
    public let totalTokens: Int
    /// Cumulative cached-read tokens (from `Usage.cachedReadTokens`), if reported.
    public let cachedReadTokens: Int?
    /// Cumulative thought/reasoning tokens (from `Usage.thoughtTokens`), if reported.
    public let thoughtTokens: Int?
    /// The last reported cost amount (from `UsageUpdate.cost.amount`), if any.
    public let cost: Double?
    /// The cost currency (e.g. "USD"), if cost was reported.
    public let currency: String?
    /// Tokens used in the context window (from `UsageUpdate.used`).
    public let contextUsed: Int
    /// Total context window size (from `UsageUpdate.size`).
    public let contextSize: Int
    /// The provider label (e.g. "Claude", "Hermes") for the run, if known.
    /// Point-in-time (latest non-nil wins on merge), like cost/currency.
    public let providerLabel: String?
    /// The model id the session actually used (`ModelsInfo.currentModelId`),
    /// if reported. Point-in-time — latest non-nil wins on merge.
    public let modelId: String?
    /// The human-readable model name (e.g. "Claude Sonnet 4.5") resolved from
    /// the agent's advertised `ModelsInfo.availableModels` by matching
    /// `modelId`. Falls back to `nil` when the agent didn't advertise a list
    /// or no entry matches `currentModelId` (caller can fall back to `modelId`
    /// for display). Point-in-time — latest non-nil wins on merge, matching
    /// `modelId`. Used by the per-model usage breakdown (#583).
    public let modelName: String?
    /// #566: the active thinking-effort level (`thought_level` config option's
    /// current value, e.g. `"high"`/`"medium"`/`"low"`), if the agent advertises
    /// one. Point-in-time — latest non-nil wins on merge. Surfaced in the
    /// Activity window between the model id and the token counts.
    public let thinkingLevel: String?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        cachedReadTokens: Int?,
        thoughtTokens: Int?,
        cost: Double?,
        currency: String?,
        contextUsed: Int,
        contextSize: Int,
        providerLabel: String? = nil,
        modelId: String? = nil,
        modelName: String? = nil,
        thinkingLevel: String? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedReadTokens = cachedReadTokens
        self.thoughtTokens = thoughtTokens
        self.cost = cost
        self.currency = currency
        self.contextUsed = contextUsed
        self.contextSize = contextSize
        self.providerLabel = providerLabel
        self.modelId = modelId
        self.modelName = modelName
        self.thinkingLevel = thinkingLevel
    }

    /// Merge two usage snapshots for run-total accumulation (#528 spike).
    /// Token counts are summed; context window + cost reflect the most recent
    /// snapshot (they are point-in-time, not cumulative across phases).
    /// `existing == nil` returns `new` directly.
    public static func merging(_ existing: SessionUsage?, _ new: SessionUsage) -> SessionUsage {
        guard let existing else { return new }
        let mergedCost: Double?
        if let e = existing.cost, let n = new.cost {
            mergedCost = e + n
        } else {
            mergedCost = new.cost ?? existing.cost
        }
        return SessionUsage(
            inputTokens: existing.inputTokens + new.inputTokens,
            outputTokens: existing.outputTokens + new.outputTokens,
            totalTokens: existing.totalTokens + new.totalTokens,
            cachedReadTokens: (existing.cachedReadTokens ?? 0) + (new.cachedReadTokens ?? 0),
            thoughtTokens: (existing.thoughtTokens ?? 0) + (new.thoughtTokens ?? 0),
            cost: mergedCost,
            currency: new.currency ?? existing.currency,
            contextUsed: new.contextUsed,
            contextSize: new.contextSize,
            providerLabel: new.providerLabel ?? existing.providerLabel,
            modelId: new.modelId ?? existing.modelId,
            modelName: new.modelName ?? existing.modelName,
            thinkingLevel: new.thinkingLevel ?? existing.thinkingLevel)
    }

    /// Compute the incremental usage between two cumulative snapshots of the
    /// SAME session (`from` = an earlier `sessionUsage(for:)` result, `to` = a
    /// later one). The backend's `sessionUsage(for:)` returns cumulative
    /// session totals (tokens across all turns, last-reported cost). Emitting
    /// those after each interactive turn and adding them into `DailyUsage.add`
    /// would double-count — so the interactive path emits this delta.
    ///
    /// Semantics:
    /// - Token counts (cumulative across turns): `to − from`. `from == nil`
    ///   (first turn) returns `to` directly.
    /// - `cost` / `currency`: cost is point-in-time (last reported) but
    ///   represents cumulative session cost; delta = `to.cost − from.cost`
    ///   (both present), else the new cost. Currency takes the latest.
    /// - `contextUsed` / `contextSize`: point-in-time snapshot, not
    ///   cumulative — takes `to`'s values.
    /// - `providerLabel` / `modelId` / `thinkingLevel`: point-in-time
    ///   metadata — latest non-nil wins, matching `merging`.
    public static func delta(from: SessionUsage?, to new: SessionUsage) -> SessionUsage {
        guard let from else { return new }
        let deltaCost: Double?
        if let f = from.cost, let n = new.cost {
            deltaCost = max(0, n - f)
        } else {
            deltaCost = new.cost
        }
        return SessionUsage(
            inputTokens: max(0, new.inputTokens - from.inputTokens),
            outputTokens: max(0, new.outputTokens - from.outputTokens),
            totalTokens: max(0, new.totalTokens - from.totalTokens),
            cachedReadTokens: max(0, (new.cachedReadTokens ?? 0) - (from.cachedReadTokens ?? 0)),
            thoughtTokens: max(0, (new.thoughtTokens ?? 0) - (from.thoughtTokens ?? 0)),
            cost: deltaCost,
            currency: new.currency ?? from.currency,
            contextUsed: new.contextUsed,
            contextSize: new.contextSize,
            providerLabel: new.providerLabel ?? from.providerLabel,
            modelId: new.modelId ?? from.modelId,
            thinkingLevel: new.thinkingLevel ?? from.thinkingLevel)
    }
}

// MARK: - PendingPermission

// `PendingPermission` was extracted from ACPPermissions.swift so the queue
// system (QueueWorker, QueueIngestionProvider) compiles on Linux.

/// A pending permission request surfaced by the agent for user approval.
/// Captured by `ACPPermissionDelegate` and emitted to the UI / queue.
public struct PendingPermission: Sendable, Equatable {
    public let toolCallId: String
    public let title: String?
    /// A human-readable tool name (e.g. "Edit file", "Create directory").
    /// Derived from the permission request's `ToolCallUpdate.title`/`.kind`.
    public let toolName: String?
    /// A one-liner summary of what the tool will do (e.g. the file path being
    /// edited). Derived from `ToolCallUpdate.locations`.
    public let inputSummary: String?
    public let options: [PermissionOption]

    public init(
        toolCallId: String, title: String?, toolName: String?,
        inputSummary: String?, options: [PermissionOption]
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.toolName = toolName
        self.inputSummary = inputSummary
        self.options = options
    }

    public static func == (lhs: PendingPermission, rhs: PendingPermission) -> Bool {
        lhs.toolCallId == rhs.toolCallId
    }
}

// MARK: - PermissionPolicy

// `PermissionPolicy` was extracted from ACPPermissions.swift so
// AgentBackendFactory and AgentLauncher can reference it on Linux for
// queue test fixtures.

/// The permission gate policy for an agent session.
public enum PermissionPolicy: String, Sendable, CaseIterable {
    /// Skip all permission prompts — writes apply automatically.
    case bypass
    /// Pause for user approval before each tool that needs permission.
    case alwaysAsk
    /// Auto-approve edit/write tools; ask for everything else.
    case acceptEdits
    /// Deny all writes — read-only analysis mode.
    case plan

    public var label: String {
        switch self {
        case .bypass: "Bypass"
        case .alwaysAsk: "Always Ask"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan"
        }
    }

    public var help: String {
        switch self {
        case .bypass: "Skip all permission prompts (use with caution)"
        case .alwaysAsk: "Pause for your approval before each write"
        case .acceptEdits: "Auto-approve file edits; ask for other tools"
        case .plan: "Read-only: deny all writes and edits"
        }
    }

    /// SF Symbol for the mode's composer chip + dropdown row. A shield motif
    /// echoing paseo's permission menu (bolt = skip/fast, checkmark = safe/ask,
    /// exclamation = auto-apply edits, half-shield = read-only plan).
    public var glyph: String {
        switch self {
        case .bypass: "bolt.shield"
        case .alwaysAsk: "checkmark.shield"
        case .acceptEdits: "exclamationmark.shield"
        case .plan: "shield.lefthalf.filled"
        }
    }
}

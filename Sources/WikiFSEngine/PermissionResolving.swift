import Foundation
import WikiFSCore

/// An optional capability a backend MAY expose: surfacing + resolving pending
/// write-permission requests (the always-ask lever, `plans/acp-backend-and-permissions.md`).
///
/// `ACPBackend` conforms (it owns the `session/request_permission` channel via
/// `ACPPermissionDelegate`); `ClaudeCLIBackend` does NOT (the CLI stream-json
/// backend has no permission channel — its writes are ungated, i.e. always yolo).
/// The launcher downcasts `backend as? PermissionResolving` to decide whether to
/// poll for pending requests and offer Approve/Reject in the chat. When the cast
/// fails (CLI backend), the always-ask/yolo toggle has no effect and the UI
/// hides the approval affordance.
///
/// Conforms to `AgentBackend` so the launcher holds a single `backend:
/// AgentBackend` and conditionally queries this capability — no second property,
/// no protocol-violating optionality on the base port.
protocol PermissionResolving: AgentBackend {
    /// The currently-pending permission requests for a session (always-ask
    /// mode). Empty when yolo, or when nothing is awaiting approval.
    func pendingPermissions(sessionHandle: SessionHandle) async -> [PendingPermission]

    /// Resolve a pending request by selecting one of its offered option ids.
    /// Returns `true` if a pending request offering that option was resolved
    /// (and the agent was thereby unblocked). The Approve/Reject UI calls this.
    func resolvePermission(sessionHandle: SessionHandle, optionId: String) async -> Bool

    /// Drain every pending always-ask request for a session, resuming each as
    /// cancelled. Called on teardown/cancel so no `CheckedContinuation` leaks.
    /// Returns the count drained (for tests).
    @discardableResult
    func cancelAllPending(sessionHandle: SessionHandle) async -> Int
}

// MARK: - ACPBackend conformance

// `ACPBackend` already implements all three methods; this extension just
// declares protocol membership. Kept here (not in ACPBackend.swift) so the
// capability seam is discoverable in one place alongside the protocol.
#if os(macOS)
extension ACPBackend: PermissionResolving {}
#endif

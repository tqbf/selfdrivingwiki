// pattern: Imperative Shell

import Observation
import SwiftUI
import WikiFSCore

/// Window-owned registration describing the active tab's trailing sidebar.
/// The shell renders this as a sibling column, while detail views keep owning
/// their local state and callbacks.
struct RightSidebarRegistration {
    /// The detail selection that owns this registration. Async work from a
    /// departing detail can finish after the next detail appears, so the
    /// controller accepts the payload only while this subject is still active.
    let subject: WikiSelection
    let inspectorTab: Binding<InspectorTab>
    let outlineWidth: Binding<Double>
    let availableTabs: [InspectorTab]
    let metadataState: MetadataHydrationState
    let origin: ProvenanceEntry?
    let history: [ProvenanceEntry]
    let onOpenChat: (ChatID) -> Void
    let onCompareVersions: (() -> Void)?
    let metadataRouter: MetadataActionRouter
    let outline: () -> AnyView
}

/// Window-scoped state for the unified trailing sidebar. Detail surfaces
/// register the active sidebar payload; the window toolbar owns the single
/// show/hide toggle and the shell owns the actual trailing column.
@MainActor
@Observable
final class WindowRightInspectorController {
    var isPresented = false
    var registration: RightSidebarRegistration?

    var isAvailable: Bool { registration != nil }

    /// Replaces the sidebar payload only when its owner is still the active
    /// detail. SwiftUI may finish a canceled task or deliver an `onChange`
    /// callback from the outgoing page/source/chat after the incoming detail
    /// has registered; rejecting that stale write keeps the new outline alive.
    func updateRegistration(
        _ registration: RightSidebarRegistration,
        activeSelection: WikiSelection?
    ) {
        guard registration.subject == activeSelection else {
            DebugLog.tabs(
                "Right inspector ignored stale registration: subject=\(registration.subject) active=\(String(describing: activeSelection))"
            )
            return
        }
        self.registration = registration
    }

    /// Clears sidebar availability for selections that have no inspector.
    /// This is owned by the window selection seam rather than departing detail
    /// views, so an old detail cannot close a newly registered inspector.
    func clearRegistration() {
        registration = nil
        isPresented = false
    }

    func toggle() {
        guard isAvailable else { return }
        isPresented.toggle()
    }
}

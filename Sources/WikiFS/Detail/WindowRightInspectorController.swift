// pattern: Imperative Shell

import Observation
import SwiftUI
import WikiFSCore

/// Window-owned registration describing the active tab's trailing sidebar.
/// The shell renders this as a sibling column, while detail views keep owning
/// their local state and callbacks.
struct RightSidebarRegistration {
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

    func updateRegistration(_ registration: RightSidebarRegistration?) {
        self.registration = registration
        if registration == nil {
            isPresented = false
        }
    }

    func toggle() {
        guard isAvailable else { return }
        isPresented.toggle()
    }
}

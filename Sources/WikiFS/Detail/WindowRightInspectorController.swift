// pattern: Imperative Shell

import Observation

/// Window-scoped state for the unified trailing inspector. Detail surfaces
/// publish whether they currently have inspector content; the window toolbar
/// owns the single show/hide toggle.
@MainActor
@Observable
final class WindowRightInspectorController {
    var isPresented = false
    var isAvailable = false

    func updateAvailability(_ isAvailable: Bool) {
        self.isAvailable = isAvailable
        if !isAvailable {
            isPresented = false
        }
    }

    func toggle() {
        guard isAvailable else { return }
        isPresented.toggle()
    }
}

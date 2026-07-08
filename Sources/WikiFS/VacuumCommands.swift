import SwiftUI
import WikiFSCore

/// Help-menu command for reclaiming orphaned storage (#253 + #257). Opens a
/// confirm alert (a read-only dry-run preview → Vacuum / Cancel) that sweeps
/// both orphaned blobs and orphaned activities in one pass. The wiring lives
/// in `WikiManager.previewVacuumAll` / `applyVacuumAll` and the alert is hosted
/// on the app's root scene. Menu items that open a dialog end with "…" (macOS
/// convention).
struct VacuumCommands: Commands {
    let manager: WikiManager

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Vacuum All…") {
                manager.previewVacuumAll()
            }
        }
    }
}

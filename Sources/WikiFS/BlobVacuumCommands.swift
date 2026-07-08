import SwiftUI
import WikiFSCore

/// Help-menu command for reclaiming orphaned blob storage (#253). Opens a
/// confirm alert (a read-only dry-run preview → Vacuum / Cancel); the wiring
/// lives in `WikiManager.previewBlobVacuum` / `applyBlobVacuum` and the alert is
/// hosted on the app's root scene. Menu items that open a dialog end with "…"
/// (macOS convention).
struct BlobVacuumCommands: Commands {
    let manager: WikiManager

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Vacuum Orphaned Storage…") {
                manager.previewBlobVacuum()
            }
        }
    }
}

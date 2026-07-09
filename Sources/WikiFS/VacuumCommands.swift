import SwiftUI
import WikiFSCore

/// Help-menu commands for wiki maintenance and diagnostics (#253 + #257 + #282).
///
/// Two kinds of items live here:
///   * **Actions** that open a confirm dialog (end with "…", macOS convention) —
///     "Vacuum All…" reclaims orphaned blobs and activities in one pass
///     (`WikiManager.previewVacuumAll` / `applyVacuumAll`, hosted on the root scene).
///   * **Navigation** items that open a maintenance/detail tab in the main
///     window — Lint, Agent Instructions, and Activity Log. These were moved out
///     of the Chats sidebar tab (issue #282) so that tab is a pure chat list.
///     They reuse the existing `WikiSelection` destinations already rendered by
///     `WikiDetailView`.
struct VacuumCommands: Commands {
    let manager: WikiManager

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Vacuum All…") {
                manager.previewVacuumAll()
            }

            Divider()

            Button("Lint Wiki") {
                manager.activeStore?.openTab(.lint)
            }
            Button("Agent Instructions") {
                manager.activeStore?.openTab(.systemPrompt)
            }
            Button("Activity Log") {
                manager.activeStore?.openTab(.changeLog)
            }
        }
    }
}

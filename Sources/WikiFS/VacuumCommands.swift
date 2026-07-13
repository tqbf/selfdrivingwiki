import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Help-menu commands for wiki maintenance and diagnostics (#253 + #257 + #282).
///
/// Two kinds of items live here:
///   * **Actions** that open a confirm dialog (end with "…", macOS convention) —
///     "Vacuum All…" reclaims orphaned blobs and activities in one pass
///     (`WikiSession.previewVacuumAll` / `applyVacuumAll`, hosted on the root scene).
///   * **Navigation** items that open a maintenance/detail tab in the main
///     window — Lint, Agent Instructions, and Activity Log. These were moved out
///     of the Chats sidebar tab (issue #282) so that tab is a pure chat list.
///     They reuse the existing `WikiSelection` destinations already rendered by
///     `WikiDetailView`.
struct VacuumCommands: Commands {
    /// The shared session manager — resolves the frontmost window's session
    /// via `frontmostSession` (updated by per-window scenePhase transitions).
    /// `.commands` is a `Scene` modifier (not a `View` modifier), so this
    /// lives at the app level, not inside `RootScene`.
    let sessionManager: SessionManager

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Vacuum All…") {
                sessionManager.frontmostSession?.previewVacuumAll()
            }

            Divider()

            Button("Lint Wiki") {
                sessionManager.frontmostSession?.store.openTab(.lint)
            }
            Button("Agent Instructions") {
                sessionManager.frontmostSession?.store.openTab(.systemPrompt)
            }
            Button("Activity Log") {
                sessionManager.frontmostSession?.store.openTab(.changeLog)
            }
        }
    }
}

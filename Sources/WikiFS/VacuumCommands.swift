import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Help-menu commands. Wiki maintenance actions (Vacuum All, Lint Wiki, Agent
/// Instructions, Activity Log) have moved to the menu-bar status item dropdown.
/// This command group is kept as an empty placeholder so the Help menu doesn't
/// show a stale "Self Driving Wiki" section.
struct VacuumCommands: Commands {
    let sessionManager: SessionManager

    var body: some Commands {
        CommandGroup(after: .help) {
            // Wiki maintenance is now in the menu-bar dropdown (books icon).
            EmptyView()
        }
    }
}

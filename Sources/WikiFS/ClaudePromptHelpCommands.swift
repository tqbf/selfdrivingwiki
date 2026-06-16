import SwiftUI

/// Help menu command for the secondary prompt reference window.
struct ClaudePromptHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Claude Prompt Templates") {
                openWindow(id: "claudePromptHelp")
            }
            .keyboardShortcut("/", modifiers: [.command, .option])
        }
    }
}

import SwiftUI
import WikiFSCore

/// The Agent section — a small SwiftUI `List` of the agent mode entries (Ask /
/// Edit / Lint / Activity / Instructions). These are navigation items, so
/// single-click selects AND opens (the binding's `set` calls `store.openTab`),
/// restoring the behavior the shared-`List` had before the double-click
/// experiment. No per-row gesture, so no latency.
struct AgentToolsView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent").font(.headline).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            List(selection: Binding(
                get: { store.activeTab?.selection },
                set: { sel in if let sel { store.openTab(sel) } }
            )) {
                SidebarModeRow(title: "Ask", subtitle: "Read-only Q&A",
                    systemImage: "bubble.left.and.text.bubble.right")
                    .tag(WikiSelection.ask)
                    .help("Chat with the agent — read-only, the agent cannot write the wiki.")

                SidebarModeRow(title: "Edit", subtitle: "Ask & update the wiki",
                    systemImage: "square.and.pencil")
                    .tag(WikiSelection.edit)
                    .help("Chat with the agent and let it update the wiki.")

                SidebarModeRow(title: "Lint", subtitle: "Health-check the wiki",
                    systemImage: "checkmark.shield")
                    .tag(WikiSelection.lint)
                    .help("Check the wiki for stale content, broken links, and inconsistencies")

                SidebarModeRow(title: "Activity", subtitle: "Operation log",
                    systemImage: "clock.arrow.circlepath")
                    .tag(WikiSelection.changeLog)
                    .help("Operation history, projected read-only as log.md")

                SidebarModeRow(title: "Instructions", subtitle: "Agent prompt",
                    systemImage: "sparkles")
                    .tag(WikiSelection.systemPrompt)
                    .help("Agent instructions, projected read-only as CLAUDE.md and AGENTS.md")
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

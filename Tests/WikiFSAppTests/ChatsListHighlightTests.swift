#if os(macOS)
import AppKit
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Sidebar highlight reconciliation: the active `.chat(id)` tab highlights its
/// persisted row; any other selection clears the highlight. New chats are
/// persisted before their tabs open, so a `.chat(id)` selection always has a
/// real row — there is no optimistic draft highlight anymore.
@MainActor
struct ChatsListHighlightTests {

    private func summary(id: String, title: String) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: id),
            kind: .edit,
            title: title,
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 0)
    }

    @Test("A .chat selection highlights its row; other selections clear it")
    func chatRowsHighlightBySelection() {
        let vc = ChatsListViewController()
        _ = vc.view // triggers loadView → table construction

        let empty = summary(id: "0199-empty-chat", title: "")
        let committed = summary(id: "0199-real-chat", title: "Hello world")
        vc.reloadData(from: [empty, committed])

        // The active durable chat (empty title or not) highlights its row.
        vc.reconcileHighlight(activeSelection: .chat(empty.id))
        #expect(vc.tableView.selectedRow == 0)

        vc.reconcileHighlight(activeSelection: .chat(committed.id))
        #expect(vc.tableView.selectedRow == 1)

        // An unrelated selection clears the highlight (existing behavior).
        vc.reconcileHighlight(activeSelection: .page(PageID(rawValue: "p1")))
        #expect(vc.tableView.selectedRow == -1)

        // A legacy .newChat navigation intent has no row to highlight — it
        // clears rather than pointing at a stale row.
        vc.reconcileHighlight(activeSelection: .newChat)
        #expect(vc.tableView.selectedRow == -1)
    }
}
#endif

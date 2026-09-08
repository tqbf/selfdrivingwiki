#if os(macOS)
import AppKit
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Regression coverage for the #1223 highlight criterion: while a new-chat
/// draft is open, the Chats sidebar keeps the draft's optimistic row
/// selected, and the selection moves to the committed row after the
/// draft→persisted morph.
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

    @Test("A .newChat draft selection highlights the optimistic row; a committed chat highlights its row")
    func draftAndCommittedRowsHighlight() {
        let vc = ChatsListViewController()
        _ = vc.view // triggers loadView → table construction

        let draft = summary(id: "0199-draft-chat", title: "")
        let committed = summary(id: "0199-real-chat", title: "Hello world")
        vc.reloadData(from: [draft, committed])

        // While the draft editor is open, its optimistic row is highlighted.
        vc.reconcileHighlight(activeSelection: .newChat, draftChatID: draft.id)
        #expect(vc.tableView.selectedRow == 0)

        // After the first send the selection is the committed chat; the
        // highlight moves to that row.
        vc.reconcileHighlight(activeSelection: .chat(committed.id), draftChatID: nil)
        #expect(vc.tableView.selectedRow == 1)

        // An unrelated selection clears the highlight (existing behavior).
        vc.reconcileHighlight(activeSelection: .page(PageID(rawValue: "p1")), draftChatID: nil)
        #expect(vc.tableView.selectedRow == -1)
    }
}
#endif

import SwiftUI

/// A large title that can be renamed in place. Shows the title as bold text;
/// a double-click (or right-click → Rename) swaps it for a focused text field.
/// Return — or clicking away (focus loss) — commits the trimmed text; Escape
/// cancels. A commit is a no-op when the text is empty or unchanged, so the
/// caller's `onCommit` only fires for a real rename.
///
/// View-only: the caller owns persistence via `onCommit` (e.g. `store.rename` for
/// a page, `store.renameSource` for a source). Used by the page and source detail
/// headers so a title can be edited straight from the detail page.
struct EditableTitle: View {
    /// The current title (the committed value). The field seeds from this on edit.
    let title: String
    /// Shown when `title` is blank, and used as the baseline so committing the
    /// placeholder text doesn't count as a change.
    var placeholder: String = "Untitled"
    var font: Font = .largeTitle
    /// Display-mode line cap (the editing field is always single-line). `nil` = no cap.
    var lineLimit: Int? = nil
    /// When true, double-click and the Rename menu item are inert (e.g. while the
    /// agent is updating the wiki).
    var isDisabled: Bool = false
    /// Single-tap on the title text. The detail header uses this to toggle
    /// expand/collapse, so a click anywhere on the row toggles — not just the
    /// empty space beside the title. Defaults to nil so other callers are unaffected.
    var onSingleTap: (() -> Void)? = nil
    /// Called with the new trimmed title on a real rename (non-empty, changed).
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var display: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? placeholder : title
    }

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $draft)
                    .font(font)
                    .fontWeight(.bold)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: focused) { _, isFocused in
                        // Clicking away commits whatever is in the field.
                        if !isFocused { commit() }
                    }
            } else {
                Text(display)
                    .font(font)
                    .fontWeight(.bold)
                    .lineLimit(lineLimit)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { begin() }
                    .onTapGesture(count: 1) { onSingleTap?() }
                    .contextMenu {
                        Button("Rename") { begin() }
                            .disabled(isDisabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(display, forType: .string)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Bail out of an in-progress edit if the underlying title changes from
        // outside (e.g. the user navigates to a different page/source — the view
        // is reused, so @State would otherwise leak the old draft over it).
        .onChange(of: title) { isEditing = false }
    }

    private func begin() {
        guard !isDisabled else { return }
        draft = title
        isEditing = true
        // Focus after the field has mounted, or the binding has nothing to bind to.
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard isEditing else { return }   // already cancelled / committed
        isEditing = false
        if let value = Self.committedValue(draft: draft, current: title) {
            onCommit(value)
        }
    }

    /// Pure decision: the value to hand `onCommit` for a rename, or `nil` to skip.
    /// Trims surrounding whitespace and skips an empty or unchanged title, so a
    /// rename only fires for a real change. Extracted so the rule is unit-testable
    /// without driving SwiftUI state.
    static func committedValue(draft: String, current: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }

    private func cancel() {
        // Drop the draft without committing. The blur-driven commit that follows
        // is a no-op because `isEditing` is already false.
        isEditing = false
    }
}

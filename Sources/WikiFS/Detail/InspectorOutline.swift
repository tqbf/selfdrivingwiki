// pattern: Value Object + Pure Rendering

import SwiftUI
import WikiFSCore

/// One outline entry for page/source markdown. `id` is the anchor slug — the
/// same slug the HTML renderer puts on the heading element — and `charOffset`
/// is the NSString (UTF-16) offset of the heading's line start within the
/// source markdown, the coordinate space the editors' `NSTextView` ranges use.
struct OutlineHeading: Equatable, Identifiable {
    let id: String
    let text: String
    let level: Int
    let charOffset: Int
}

/// What the outline pane shows for a registered subject. The two content
/// kinds carry their rows as values so the registration never depends on
/// view-local state at render time.
enum InspectorOutlineContent: Equatable {
    /// Markdown headings (page and source surfaces).
    case headings([OutlineHeading])
    /// Chat turns (chat surface).
    case chatTurns([ChatOutlineEntry])
}

/// The outline payload a detail view registers with the right inspector.
/// Detail views derive this as a value in their body — caret moves and
/// transcript changes re-derive it — and the shell renders it through the
/// single `InspectorOutlineView`. Values, not view-producing closures, so a
/// registration cannot outlive the local state a closure would capture.
struct InspectorOutlinePayload: Equatable {
    /// The detail selection that produced this payload. The controller
    /// rejects registrations whose subject is no longer active; tests assert
    /// on this field to attribute an accepted payload to its surface.
    let subject: WikiSelection
    let content: InspectorOutlineContent
    /// Outline row id (heading slug or chat turn id) currently highlighted.
    /// For pages and sources this is the heading containing the caret
    /// (issue #268); chats leave it `nil`.
    let highlightedItemID: String?

    var rowCount: Int {
        switch content {
        case .headings(let headings): return headings.count
        case .chatTurns(let turns): return turns.count
        }
    }

    var isEmpty: Bool { rowCount == 0 }

    /// Stable name for the content kind, for the controller's acceptance log.
    var contentKindDescription: String {
        switch content {
        case .headings: return "headings"
        case .chatTurns: return "chatTurns"
        }
    }
}

/// A tap on an outline row, routed through the registration back to the
/// producer that owns the jump/scroll behavior.
enum InspectorOutlineSelection {
    case heading(OutlineHeading)
    case chatTurn(ChatOutlineEntry.ID)
}

/// The single renderer for every registered `InspectorOutlinePayload`.
/// Row styling preserves the former per-surface views: markdown headings keep
/// `PageOutlineView`'s indentation, hover cursor, active-heading highlight,
/// and auto-scroll; chat turns keep `ChatInspectorOutlineView`'s timestamped,
/// drag-selectable rows. An empty payload renders an explicit empty state —
/// never blank space.
struct InspectorOutlineView: View {
    let payload: InspectorOutlinePayload
    let onSelect: (InspectorOutlineSelection) -> Void

    var body: some View {
        let _ = DebugLog.tabs(
            "Inspector outline redraw: subject=\(payload.subject) rows=\(payload.rowCount)"
        )
        return Group {
            if payload.isEmpty {
                emptyState
            } else {
                switch payload.content {
                case .headings(let headings):
                    headingsList(headings)
                case .chatTurns(let entries):
                    chatTurnsList(entries)
                }
            }
        }
    }

    // MARK: - Empty state

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            switch payload.content {
            case .headings:
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 20))
                Text("No headings in this document.")
            case .chatTurns:
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 20))
                Text("No conversation turns yet.")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Markdown headings

    private func headingsList(_ headings: [OutlineHeading]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(headings) { heading in
                        let isActive = heading.id == payload.highlightedItemID
                        Button(action: {
                            onSelect(.heading(heading))
                        }) {
                            Text(heading.text)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, CGFloat((heading.level - 1) * 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .background(
                            isActive
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .id(heading.id)
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                }
                .padding()
            }
            // Fires only when the highlighted id actually changes, so a
            // caret moving within one heading does not re-scroll (issue #268).
            .onChange(of: payload.highlightedItemID) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    // MARK: - Chat turns

    private func chatTurnsList(_ entries: [ChatOutlineEntry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.id) { entry in
                    chatTurnRow(entry)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// One chat outline entry. The row action is a tap gesture rather than a
    /// Button on purpose: a Button's press gesture swallows drag events, so
    /// drag-to-select on the entry texts could never engage. With a tap
    /// gesture, a click still jumps to the turn while a drag selects text.
    private func chatTurnRow(_ entry: ChatOutlineEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let ts = entry.questionTimestamp {
                Text(ts, format: .dateTime.hour().minute())
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
            }
            HStack(alignment: .top, spacing: 4) {
                Text("•")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(entry.question.isEmpty ? "(empty)" : entry.question)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            if let response = entry.response {
                HStack(alignment: .top, spacing: 4) {
                    Text("•")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(response)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(.chatTurn(entry.id)) }
        .contextMenu {
            Button("Copy Question") {
                _ = MetadataActionRouter.systemClipboardCopy(entry.question)
            }
            if let response = entry.response {
                Button("Copy Response") {
                    _ = MetadataActionRouter.systemClipboardCopy(response)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect(.chatTurn(entry.id)) }
    }
}

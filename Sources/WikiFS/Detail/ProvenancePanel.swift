import AppKit
import SwiftUI
import WikiFSCore

/// The content of the inspector's "History" tab — origin + edit history
/// from the PROV graph. Pure-render over its inputs (no I/O); the parent
/// ``DetailInspectorView`` loads `origin` + `history` via its `.task(id:)` and
/// passes them in here. Kept self-contained so the type checker resolves the
/// `body` subtree independently.
///
/// Shared between `PageDetailView` and `SourceDetailView` via the
/// ``ProvenanceEntry`` display model — both `PageOrigin` and `SourceOrigin`
/// project to it, so the rendering code (date-first layout, operation badge,
/// agent label, clickable rows) is identical for both.
///
/// #745: history rows are clickable. A `chat:<id>` provenance entry
/// navigates to the chat tab (via `store.openTab(.chat(...))`); an
/// `agent:<kind>` one-shot-run entry opens the Activity window (via the
/// `\.openActivityWindow` environment closure). Neither applies → no-op.
struct ProvenancePanel: View {
    let origin: ProvenanceEntry?
    let history: [ProvenanceEntry]
    /// The wiki store — used to navigate to chat tabs on row click (#745).
    /// Weak-ish: the parent detail view owns a `@Bindable` reference,
    /// so this never outlives the view.
    var store: WikiStoreModel?
    @Environment(\.openActivityWindow) private var openActivityWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if history.isEmpty {
                Text("No provenance yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                sectionHeader("History")
                ForEach(history) { entry in
                    // A single timeline (newest-first). The version the page
                    // currently points at — `origin` — is tagged "Current"
                    // inline rather than shown as a separate (duplicate) row.
                    historyRow(entry, isCurrent: entry.versionID == origin?.versionID)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// Small uppercase caption titling the timeline so the list has a header.
    @ViewBuilder private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }

    @ViewBuilder private func historyRow(_ entry: ProvenanceEntry, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Date fills the row and collapses (truncates) against the
            // fixed-width badge when the panel narrows — never overflows.
            Text(ergonomicTimestamp(entry.savedAt))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Operation badge — fixed width, so badges form a tidy column
            // the date collapses against.
            operationBadge(entry.activityKind)

            // Current-version marker. Its slot is always reserved (tinted
            // clear when not current) so the badge column stays aligned.
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(isCurrent ? Color.accentColor : .clear)
                .help(isCurrent ? "Current version" : "")
        }
        .contentShape(Rectangle())
        .hoverRowBackground()
        .onTapGesture { handleProvenanceTap(entry) }
        .contextMenu { historyRowMenu(entry) }
    }

    /// Right-click actions for a history row. "Go to Source" navigates to
    /// whatever wrote the version — the chat conversation or the ingestion/
    /// agent job (#745) — and only appears when there's somewhere to go.
    @ViewBuilder private func historyRowMenu(_ entry: ProvenanceEntry) -> some View {
        if let source = navigableSource(entry) {
            Button {
                handleProvenanceTap(entry)
            } label: {
                Label(source.title, systemImage: source.icon)
            }
            Divider()
        }

        Button {
            copyToPasteboard(
                entry.savedAt.formatted(
                    .dateTime.month().day().year().hour().minute()))
        } label: {
            Label("Copy Date", systemImage: "calendar")
        }

        Button {
            copyToPasteboard(entry.versionID)
        } label: {
            Label("Copy Version ID", systemImage: "number")
        }
    }

    /// The "Go to Source" menu label + icon for a version's writer, or `nil`
    /// when the writer isn't navigable (a plain user edit, a legacy import).
    /// Mirrors the navigation targets in ``handleProvenanceTap``.
    private func navigableSource(_ entry: ProvenanceEntry) -> (title: String, icon: String)? {
        let name = entry.agentName
        if name.hasPrefix("chat:") {
            return ("Go to Chat", "bubble.left.and.bubble.right")
        }
        if name.hasPrefix("agent:") {
            let kind = String(name.dropFirst("agent:".count))
            let title = kind == "ingest" ? "Go to Ingestion Job" : "Go to Activity"
            return (title, "cpu")
        }
        return nil
    }

    /// Replace the general pasteboard with a single string (macOS clipboard).
    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Format a provenance timestamp ergonomically for the history list.
    /// Recent edits collapse to friendly day labels so the eye isn't taxed
    /// re-reading "2026" on every row; precise clock time is always kept
    /// (edits can be seconds apart):
    /// - today     → "Today at 8:44 PM"
    /// - yesterday → "Yesterday at 4:14 PM"
    /// - this week → "Wed at 3:11 PM"
    /// - this year → "Jul 19 at 3:11 PM"  (year dropped)
    /// - older     → "Mar 2, 2025 at 9:41 AM"
    private func ergonomicTimestamp(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date.now
        let time = date.formatted(.dateTime.hour().minute())

        if cal.isDateInToday(date) {
            return "Today at \(time)"
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday at \(time)"
        }
        let daysAgo = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: date),
            to: cal.startOfDay(for: now)
        ).day ?? .max
        if (2...6).contains(daysAgo) {
            let weekday = date.formatted(.dateTime.weekday(.abbreviated))
            return "\(weekday) at \(time)"
        }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.month().day())
            : date.formatted(.dateTime.month().day().year())
        return "\(day) at \(time)"
    }

    /// A compact colored badge for the provenance activity kind
    /// (`import` → blue, `edit` → green, others → gray). Makes the
    /// operation scannable in the history list.
    @ViewBuilder
    private func operationBadge(_ kind: String) -> some View {
        let color: Color = switch kind {
        case "import": .blue
        case "edit":   .green
        default:       .secondary
        }
        Text(kind.capitalized)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .frame(width: 56)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    /// Navigate to the provenance entry's origin (#745):
    /// - `chat:<id>` → open the chat tab in the wiki's tab bar.
    /// - `agent:<kind>` → open the Activity (queue) window.
    /// - Otherwise → no-op (don't break).
    private func handleProvenanceTap(_ entry: ProvenanceEntry) {
        if entry.agentName.hasPrefix("chat:") {
            let chatID = String(entry.agentName.dropFirst("chat:".count))
            guard !chatID.isEmpty else { return }
            let id = PageID(rawValue: chatID)
            DebugLog.tabs("ProvenancePanel: navigating to chat \(id.rawValue.prefix(8))")
            store?.openTab(.chat(id))
        } else if entry.agentName.hasPrefix("agent:") {
            DebugLog.tabs("ProvenancePanel: opening Activity window for \(entry.agentName)")
            openActivityWindow?()
        }
    }

}

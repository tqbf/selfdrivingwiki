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
            if let origin {
                originRow(origin)
            } else {
                Text("No provenance yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if !history.isEmpty {
                Divider().opacity(0.5)
                Text("Edit history")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(history) { entry in
                    historyRow(entry)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func originRow(_ origin: ProvenanceEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Created-by / last-edited-by-row, date-first to match the
            // history rows below.
            HStack(spacing: 6) {
                Text(origin.savedAt,
                     format: .dateTime.month().day().year().hour().minute())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                operationBadge(origin.activityKind)
                Text("by")
                    .foregroundStyle(.secondary)
                agentLabel(origin)
            }
        }
    }

    @ViewBuilder private func historyRow(_ entry: ProvenanceEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Date — leading, fixed-width for column alignment.
            Text(entry.savedAt,
                 format: .dateTime.month().day().year().hour().minute())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            operationBadge(entry.activityKind)

            agentLabel(entry)

            Spacer()

            if entry.runTitle?.isEmpty == false {
                Text(entry.runTitle!)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .contentShape(Rectangle())
        .hoverRowBackground()
        .onTapGesture { handleProvenanceTap(entry) }
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
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    /// Navigate to the provenance entry's origin (#745):
    /// - `chat:<id>` → open the chat tab in the wiki's tab bar.
    /// - `agent:<kind>` → open the Activity (queue) window.
    /// - Otherwise → no-op (don't break).
    ///
    /// Routes through `PageAuthor` (#797) — the single source of truth for the
    /// `agents.name` convention — so the navigation handler and the writer
    /// (`AgentLauncher.authorForRun`) can't drift on prefix spellings.
    private func handleProvenanceTap(_ entry: ProvenanceEntry) {
        switch PageAuthor(rawValue: entry.agentName) {
        case .chat(let chatID):
            guard !chatID.isEmpty else { return }
            let id = PageID(rawValue: chatID)
            DebugLog.tabs("ProvenancePanel: navigating to chat \(id.rawValue.prefix(8))")
            store?.openTab(.chat(id))
        case .agent:
            DebugLog.tabs("ProvenancePanel: opening Activity window for \(entry.agentName)")
            openActivityWindow?()
        case .user, .legacyImport, .other:
            // No navigation target for non-chat / non-agent authors.
            break
        }
    }

    /// Render the agent identity (#745). For `chat:<id>` agents, prefer the
    /// resolved `runTitle` (the chat's display title) over the raw ULID. When
    /// the chat has been deleted (title is nil), fall back to a muted
    /// "Deleted chat" label. For `agent:<kind>` one-shot runs, show a
    /// friendly label derived from the kind (e.g. "Ingest" / "Lint") rather
    /// than the raw `agent:ingest` string. Other kinds render verbatim.
    ///
    /// Routes through `PageAuthor` (#797) — the single source of truth for the
    /// `agents.name` convention — so the labeler and the writer
    /// (`AgentLauncher.authorForRun`) can't drift on prefix spellings.
    @ViewBuilder
    private func agentLabel(_ entry: ProvenanceEntry) -> some View {
        switch PageAuthor(rawValue: entry.agentName) {
        case .chat:
            if let runTitle = entry.runTitle, !runTitle.isEmpty {
                Label(runTitle, systemImage: "bubble.left.and.bubble.right")
                    .help(entry.agentName)
                    .foregroundStyle(.secondary)
            } else {
                // Chat was deleted or the title is unavailable — show a
                // muted placeholder instead of the raw ULID.
                Label("Deleted chat", systemImage: "bubble.left.and.bubble.right")
                    .help(entry.agentName)
                    .foregroundStyle(.tertiary)
            }
        case .agent(let kind):
            // One-shot run: resolve a friendly label from the kind suffix.
            let label = friendlyRunLabel(for: kind)
            Label(label, systemImage: "cpu")
                .help("\(kind) agent")
                .foregroundStyle(.secondary)
        case .user:
            Label(entry.agentName, systemImage: "person")
                .foregroundStyle(.secondary)
        case .legacyImport:
            Label("Imported (legacy)", systemImage: "tray.and.arrow.down")
                .foregroundStyle(.secondary)
        case .other:
            Text(entry.agentName)
                .foregroundStyle(.secondary)
        }
    }

    /// Map an `agent:<kind>` suffix to a human-readable run label (#745).
    /// `ingest` → "Ingestion", `lint` → "Lint", `query` → "Query".
    /// Unknown kinds fall back to the capitalized kind.
    private nonisolated func friendlyRunLabel(for kind: String) -> String {
        switch kind {
        case "ingest": return "Ingestion"
        case "lint": return "Lint"
        case "query": return "Query"
        default: return kind.capitalized
        }
    }
}

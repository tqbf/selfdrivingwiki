import SwiftUI
import WikiFSCore

/// #663: the **Add Provider** sheet — a non-destructive first-run + power-user
/// surface for adding an ACP agent to `agent-providers.json`.
///
/// Replaces the old three hardcoded seed buttons (`Add Claude` / `Add Hermes` /
/// `Add OpenCode`) in `AgentsSettingsView` with a generic, catalog-driven
/// flow. **Nothing is written to disk until an Add button is pressed** —
/// AC.2 (cancel = no change) is structurally enforced by leaving the parent's
/// `appendProvider(_:)` call inside each Add action.
///
/// Backed by `ACPProviderCatalog.agents` (the 11 known ACP agents) and a live
/// `ACPProviderDiscovery.discover()` PATH scan that runs OFF-main on `.task`.
/// Custom commands are honoured via the inline DisclosureGroup at the bottom.
///
/// Sheet layout (macOS 15, native idioms — see `plans/663-combined-plan.md`
/// §1.3, §3.3):
///
/// ```
/// ┌─ Add Provider ────────────────────────────  ✕ ─┐
/// │  🔍 [ Search agents…                       ]  │
/// │  INSTALLED ON THIS MAC          ↻ scanning…    │
/// │  ● Claude … [ Add ]                             │
/// │  OTHER KNOWN AGENTS                             │
/// │  ○ Gemini …  [ Add ]                            │
/// │  ▸ Custom command…                              │
/// │                                  [ Done ]       │
/// ```
struct AddProviderSheet: View {
    @State private var model: AddProviderModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    /// Invoked when an Add button is pressed. The parent persists the
    /// provider (so the sheet itself touches no state outside its model).
    let onAdd: (AgentProvider) -> Void

    /// Invoked alongside `onAdd` when the freshly-added provider should land
    /// in the editor (custom command, or a non-detected catalog agent whose
    /// PATH status the user may want to address). The parent throttles this
    /// via `DispatchQueue.main.async` so the editor sheet doesn't pre-empt
    /// this sheet's dismissal (a known SwiftUI hazard — see
    /// `plans/663-combined-plan.md` correction §5).
    let onAddNeedsEditor: (AgentProvider) -> Void

    init(
        existingIDs: Set<String>,
        onAdd: @escaping (AgentProvider) -> Void,
        onAddNeedsEditor: @escaping (AgentProvider) -> Void
    ) {
        _model = State(initialValue: AddProviderModel(existingIDs: existingIDs))
        self.onAdd = onAdd
        self.onAddNeedsEditor = onAddNeedsEditor
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.detectedFiltered.isEmpty || model.isScanning {
                        detectedSection
                    }
                    if !model.otherAgents.isEmpty {
                        otherAgentsSection
                    }
                    customDisclosure
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 520)
        .task {
            await model.scan()
            // Focus search once the sheet is up — the `.task` runs after the
            // initial render, so the field is mounted.
            searchFocused = true
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Text("Add Provider")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if model.isScanning {
                Text("Scanning PATH…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.detected.isEmpty {
                Text("No ACP agents detected on PATH — pick from the catalog below or add a custom command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.detected.count) installed · \(ACPProviderCatalog.agents.count) in catalog")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search agents…", text: $model.query)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .onSubmit { /* no-op; filter is live */ }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Sections

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("INSTALLED ON THIS MAC")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            VStack(spacing: 2) {
                ForEach(model.detectedFiltered, id: \.agent.id) { discovered in
                    AddProviderRow(
                        label: discovered.agent.label,
                        summary: discovered.agent.summary,
                        detailPath: discovered.resolvedPath,
                        available: true,
                        isAdded: model.existingIDs.contains(discovered.agent.id)) {
                        addCatalog(discovered.agent)
                    }
                }
            }
        }
    }

    private var otherAgentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OTHER KNOWN AGENTS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(model.otherAgents) { agent in
                    AddProviderRow(
                        label: agent.label,
                        summary: agent.summary,
                        detailPath: nil,
                        available: false,
                        isAdded: model.existingIDs.contains(agent.id)) {
                        addCatalog(agent)
                    }
                }
            }
        }
    }

    private var customDisclosure: some View {
        DisclosureGroup(isExpanded: $model.showCustom) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Name") {
                    TextField("My Agent", text: $model.customName)
                        .frame(maxWidth: 220)
                }
                LabeledContent("Command") {
                    TextField("opencode acp", text: $model.customCommand)
                        .frame(maxWidth: 220)
                }
                HStack {
                    Spacer()
                    Button("Add Custom") { addCustom() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAddCustom)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Custom command", systemImage: "terminal")
                .font(.body)
        }
        .padding(8)
    }

    // MARK: - Actions

    private var canAddCustom: Bool {
        !model.customName.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.customCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addCatalog(_ agent: KnownACPAgent) {
        let provider = AgentProvider.acp(from: agent)
        handleAdd(provider)
    }

    private func addCustom() {
        let id = model.freshCustomID()
        let argv = ShellWords.split(model.customCommand)
        let provider = AgentProvider(
            id: id,
            label: model.customName.trimmingCharacters(in: .whitespaces),
            command: argv.isEmpty ? nil : argv,
            env: [:],
            enabled: true,
            isDefault: false)
        handleAdd(provider)
    }

    private func handleAdd(_ provider: AgentProvider) {
        // Persist via the parent (the parent owns `config` + the `containerDirectory`).
        // The needsEditor heuristic (correction §4) drops the non-existent
        // `catalogEntryRequiresKey` reference and keys off `model.detected`:
        // a freshly-added detected agent skips the editor (fast path); a
        // custom provider or a non-detected catalog agent lands in the editor
        // for env/key/command follow-up.
        let needsEditor = model.needsEditor(for: provider)
        onAdd(provider)
        if needsEditor {
            onAddNeedsEditor(provider)
        }
        dismiss()
    }
}

// MARK: - Row

/// One row in the Add Provider sheet: agent label, summary, optional PATH
/// status, and an Add button (or a dimmed "✓ Added" chip when the agent is
/// already configured — dedup `existingIDs` against the parent's config).
private struct AddProviderRow: View {
    let label: String
    let summary: String
    let detailPath: String?
    let available: Bool
    let isAdded: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(available ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label).fontWeight(.medium)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let detailPath {
                    Text(detailPath)
                        .font(.caption2)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("not found on PATH")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isAdded {
                Label("Added", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("Already added to your providers")
            } else {
                Button("Add", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .opacity(isAdded ? 0.55 : 1.0)
        .disabled(isAdded)
    }
}

// MARK: - View model

/// The `@Observable` view model for `AddProviderSheet`. Owns the live PATH
/// discovery scan (off-main) + the search filter; the catalog list is
/// sourced from `ACPProviderCatalog.agents` (11 entries).
@MainActor
@Observable
final class AddProviderModel {
    /// The search query (filters both `detected` and `otherAgents` over
    /// `label` + `summary`, case-insensitive).
    var query = ""

    /// ACP agents found on the login-shell PATH during the last scan.
    /// Populated by `scan()`; empty until the scan completes (and the parent
    /// view hides the *Installed on this Mac* section when this is empty
    /// AND `isScanning == false`).
    var detected: [DiscoveredACPAgent] = []

    /// True while the PATH scan is in flight. Drives the spinner + the
    /// "scanning PATH…" caption.
    var isScanning = true

    /// Custom-command fields.
    var customName = ""
    var customCommand = ""
    var showCustom = false

    /// IDs already configured in the parent's `agent-providers.json`. Used to
    /// dedupe against the catalog (rows in `existingIDs` show "✓ Added"
    /// instead of an Add button). Immutable for the sheet's lifetime — the
    /// parent passes a fresh snapshot at construction.
    let existingIDs: Set<String>

    init(existingIDs: Set<String>) {
        self.existingIDs = existingIDs
    }

    /// Catalog agents NOT already added AND NOT in `detected`, filtered by
    /// `query`. Each renders an "Other known agent" row in the sheet.
    var otherAgents: [KnownACPAgent] {
        let detectedIDs = Set(detected.map(\.agent.id))
        return ACPProviderCatalog.agents
            .filter { !existingIDs.contains($0.id) && !detectedIDs.contains($0.id) }
            .filter { matchesQuery($0) }
    }

    /// `detected` filtered by `query` (the *Installed on this Mac* rows).
    var detectedFiltered: [DiscoveredACPAgent] {
        detected.filter { matchesQuery($0.agent) }
    }

    /// Run the live PATH discovery off-main. The default resolver does a
    /// `zsh -lc 'echo $PATH'` hop (because the GUI app's process PATH isn't
    /// the user's login PATH) — never call this on the main actor.
    func scan() async {
        isScanning = true
        let found = await Task.detached { ACPProviderDiscovery.discover() }.value
        detected = found
        isScanning = false
    }

    /// Heuristic (correction §4): the editor should auto-open for a freshly-
    /// added provider when (a) the command is empty (custom add) or (b) the
    /// agent wasn't detected on PATH (catalog add for an agent whose binary
    /// is missing — the user may want to tweak the command/env/key). A cleanly
    /// detected catalog agent skips the editor (the fast path).
    func needsEditor(for provider: AgentProvider) -> Bool {
        if provider.command?.isEmpty ?? true { return true }
        return !detected.contains(where: { $0.agent.id == provider.id })
    }

    /// `custom` / `custom-2` / `custom-3` … — the existing collision-loop
    /// carried over from the old `addCustom()` so copied/pasted config IDs
    /// don't clash with the first custom provider a user adds.
    func freshCustomID() -> String {
        var id = "custom"
        var suffix = 1
        while existingIDs.contains(id) {
            suffix += 1
            id = "custom-\(suffix)"
        }
        return id
    }

    private func matchesQuery(_ agent: KnownACPAgent) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return agent.label.localizedCaseInsensitiveContains(q)
            || agent.summary.localizedCaseInsensitiveContains(q)
    }
}

// MARK: - Empty state + badges

/// Empty-state affordance for the Providers list (shown when
/// `config.providers.isEmpty` — e.g. a corrupt config wiped the list).
/// Uses the native macOS 15 `ContentUnavailableView` rather than a hand-
/// rolled VStack (matches `ChangeLogDetailView` and `ActivityWindowView`).
struct ProvidersEmptyState: View {
    let showAddSheet: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No agents configured yet", systemImage: "sparkles")
        } description: {
            Text("Add an ACP agent to start chatting and ingesting.")
        } actions: {
            Button("Add Provider", action: showAddSheet)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inline status chips for a provider row: "Default" badge (accent capsule).
/// Kept as a small pure View so the row layout stays declarative + testable.
/// Disabled providers show no badges (the leading `○` glyph from the switch
/// already conveys it — see §3.2).
struct ProviderStatusBadges: View {
    let provider: AgentProvider

    var body: some View {
        if provider.isDefault {
            Text("Default")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
    }
}

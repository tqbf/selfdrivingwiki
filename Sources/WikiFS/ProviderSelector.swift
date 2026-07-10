import SwiftUI
import WikiFSCore

/// A compact provider + model selector for the chat composer, modeled on
/// paseo's `combined-model-selector` (translated to native macOS).
///
/// **Trigger:** a leading-aligned button under the composer showing an SF
/// Symbol glyph + "Provider · Model" + a chevron (paseo places the trigger at
/// the composer's start). A small gear icon next to it opens Settings.
///
/// **Popover (paseo's dropdown, native):** a flat `List` of one row per
/// selectable (provider · model) pair — `glyph + "Provider · Model Name"` —
/// with a checkmark on the currently-selected row. Tapping a row sets that
/// provider as default + the model as the provider's persisted selection.
/// Every enabled provider is ALWAYS present:
/// - Providers WITH cached models: one row per model + a "Provider · Default"
///   row (selects the provider with no model → agent default).
/// - Providers WITHOUT cached models: a single "Provider · Default" row — so
///   the user can SELECT the provider to start a chat (the chicken-and-egg fix:
///   a provider with no models yet is no longer unselectable).
///
/// The popover also has a **search `TextField`** (filters rows by provider +
/// model name) and a **gear button** → Settings → Providers.
///
/// **Claude (CLI):** `ClaudeCLIBackend` has no ACP model discovery, so Claude's
/// model list is the hardcoded alias set (`AgentProvidersConfig.claudeCachedModels`
/// — opus/sonnet/haiku). Selecting one threads it through `--model` via
/// `providerHints["cliSelectedModel"]`.
///
/// **ACP** providers show their captured models (discovered on first chat).
/// Selecting one threads it through `providerHints["acpSelectedModelId"]` →
/// `session/set_model`.
///
/// **Default = agent default by default:** a provider with no model selected
/// uses the agent's advertised default. Existing users see zero behavior change.
struct ProviderSelector: View {
    @Bindable var launcher: AgentLauncher

    /// The selector's view of the config. Refreshed from the persisted file on
    /// appear + after each selection, so a change made in Settings is visible
    /// the next time the composer shows.
    @State private var config: AgentProvidersConfig

    /// Popover open state.
    @State private var isPresented = false

    /// The search query typed in the popover (empty = show all rows).
    @State private var searchText = ""

    @Environment(\.openSettings) private var openSettings

    init(launcher: AgentLauncher) {
        self.launcher = launcher
        // Seed off-main via the launcher's accessor so the composer never
        // blocks on file I/O at first paint.
        _config = State(initialValue: launcher.providersConfig())
    }

    /// The providers the selector surfaces (enabled only). The launcher's
    /// `selectedProvider()` never picks a disabled provider, so the list must
    /// agree — otherwise it could show a provider that won't actually be
    /// launched.
    private var pickable: [AgentProvider] {
        config.enabledProviders
    }

    private var current: AgentProvider {
        config.selectedProvider()
    }

    var body: some View {
        // Compact trigger bar hugging the composer's left edge. The whole label
        // is the popover's hit target; the gear is a separate Settings affordance.
        HStack(spacing: 4) {
            Button {
                isPresented.toggle()
            } label: {
                trigger
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                popoverContent
            }
            .help(defaultHelpText)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Open Provider settings")
        }
        .onAppear { refresh() }
        // Keep in sync if a session flips (the composer is rebuilt when a chat
        // becomes live). Cheap: it's a single file read.
        .onChange(of: launcher.activeChatID) { _, _ in refresh() }
    }

    // MARK: - Popover content (search + gear + flat list)

    /// The popover: a header row (search field + gear button) over a flat
    /// `List` of (provider · model) rows. Compact + paseo-style. The list is
    /// flat — no nesting — so search can filter across every provider + model
    /// at once (paseo's "combined model selector" UX).
    private var popoverContent: some View {
        VStack(spacing: 0) {
            popoverHeader
            Divider()
            flatModelList
        }
        .frame(minWidth: 280, idealWidth: 300, minHeight: 240, idealHeight: 360)
    }

    /// The header: a search field (leading) + a gear button (trailing). Search
    /// filters the flat list by provider name + model name. The gear opens
    /// Settings → Providers (paseo puts a per-provider gear in the drill-down;
    /// we surface a single global one here since Settings owns provider config).
    private var popoverHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            TextField("Search providers and models", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            Button {
                openSettings()
                isPresented = false
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Open Provider settings")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// The flat `List` of selectable rows. Built from `flatRows` (every enabled
    /// provider × its models, plus a "Default" row each), filtered by the
    /// search query. A checkmark marks the current selection. Selecting a row
    /// persists the provider + model and closes the popover.
    private var flatModelList: some View {
        List(selection: Binding(
            get: { selectedRowID },
            set: { newValue in selectRow(newValue) }
        )) {
            ForEach(filteredRows) { row in
                rowView(row)
                    .tag(row.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// One row: glyph + "Provider · Model" + a checkmark when selected. Paseo
    /// renders the provider glyph as a leading slot; we use an SF Symbol per
    /// backend (terminal for Claude, cpu for ACP) since we have no brand assets.
    private func rowView(_ row: SelectorRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: glyph(for: row.provider))
                .frame(width: 16)
                .foregroundStyle(row.provider.backend == .claudeCLI ? Color.purple : Color.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if row.id == selectedRowID {
                Image(systemName: "checkmark")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectRow(row.id) }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
    }

    // MARK: - Row model (flat, searchable)

    /// One selectable (provider, model) pair in the flat list. `modelId == nil`
    /// is the synthetic "Default" row (paseo's `buildSyntheticDefaultRow`):
    /// selecting it picks the provider with no model → the agent's default.
    struct SelectorRow: Identifiable {
        let provider: AgentProvider
        let modelId: String?
        let modelLabel: String
        let id: String

        /// "Provider · Model" (the title) — e.g. "Hermes · GLM-4.7", "Claude · Opus".
        var title: String {
            "\(provider.label) · \(modelLabel)"
        }

        /// A secondary subtitle. For the "Default" row we show the hint that no
        /// model is pinned (agent default). For model rows, nil (the title
        /// already carries the model name).
        var subtitle: String? {
            modelId == nil ? "Agent default" : nil
        }
    }

    /// Build the flat, unfiltered row list. Every enabled provider appears.
    /// Each provider yields a "Default" row PLUS one row per cached model
    /// (ACP-captured or Claude's hardcoded aliases). A provider with no cached
    /// models yields ONLY its "Default" row — this is the critical fix that
    /// makes a provider selectable before first chat.
    private var flatRows: [SelectorRow] {
        pickable.flatMap { provider in
            let models = config.cachedModels(forProvider: provider.id)
            // The "Default" row is ALWAYS present (selecting it picks the
            // provider with no pinned model → the agent's default).
            var rows = [
                SelectorRow(
                    provider: provider,
                    modelId: nil,
                    modelLabel: "Default",
                    id: "\(provider.id):default")
            ]
            for model in models {
                rows.append(SelectorRow(
                    provider: provider,
                    modelId: model.modelId,
                    modelLabel: model.displayLabel,
                    id: "\(provider.id):\(model.modelId)"))
            }
            return rows
        }
    }

    /// The rows after applying the search filter. Matches against the provider
    /// label + the model label (case-insensitive). Empty query = all rows.
    private var filteredRows: [SelectorRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return flatRows }
        return flatRows.filter { row in
            row.provider.label.lowercased().contains(query)
                || row.modelLabel.lowercased().contains(query)
        }
    }

    /// The id of the row that matches the current selection (provider + model),
    /// or the provider's "default" row when no model is pinned. nil when nothing
    /// matches (no providers / provider not in list).
    private var selectedRowID: String? {
        let selectedModel = config.selectedModelId(forProvider: current.id)
        if let selectedModel {
            return "\(current.id):\(selectedModel)"
        }
        return "\(current.id):default"
    }

    // MARK: - Trigger

    /// The compact trigger: glyph + "Provider · model" + chevron. `.caption`
    /// type + secondary fill so it reads as an auxiliary affordance under the
    /// composer, not a primary control. The model segment reflects the
    /// per-provider selection, or "default" when none is set.
    private var trigger: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph(for: current))
                .foregroundStyle(current.backend == .claudeCLI ? Color.purple : Color.blue)
            Text(triggerLabel)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .contentShape(Rectangle())
    }

    /// "Provider · model". For ACP providers the model is the user's selection
    /// (or "default" when none is selected); for Claude it's the selected
    /// alias (or "default").
    private var triggerLabel: String {
        "\(current.label) · \(modelSegment(for: current))"
    }

    /// The model text shown in the trigger for a provider. For ACP: the user's
    /// selection, else "default". For Claude: the selected alias, else "default".
    private func modelSegment(for provider: AgentProvider) -> String {
        if let selected = config.selectedModelId(forProvider: provider.id) {
            // Use the cached friendly name when available.
            if let cached = config.cachedModels(forProvider: provider.id)
                .first(where: { $0.modelId == selected }) {
                return cached.displayLabel
            }
            return selected
        }
        return "default"
    }

    private var defaultHelpText: String {
        if current.backend == .acp {
            return "Provider and model for new chats"
        }
        return "Default provider for new chats"
    }

    // MARK: - Actions

    /// Selecting a row parses its id back into (provider, modelId) and persists
    /// both atomically (provider as default + model as the provider's
    /// selection), then closes the popover. Mirrors paseo's "choosing a model
    /// implies choosing its provider".
    private func selectRow(_ rowID: String?) {
        guard let rowID else { return }
        // Split "providerId:modelId" (or "providerId:default"). The provider id
        // never contains a colon, so a first-split is safe.
        let parts = rowID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = config.provider(id: String(parts[0])) else { return }
        let modelId: String? = parts[1] == "default" ? nil : String(parts[1])
        DebugLog.agent("ProviderSelector.selectRow: provider=\(provider.id) modelId=\(modelId ?? "nil") (nil=Default/agent-default)") // TEMP DEBUG
        config = launcher.setSelectedModelAndDefault(modelId, provider: provider)
        isPresented = false
        searchText = ""
    }

    private func refresh() {
        config = launcher.providersConfig()
    }

    // MARK: - Glyphs

    /// SF Symbol per provider. Claude uses a terminal glyph; ACP agents share a
    /// CPU glyph (paseo uses per-provider brand glyphs we don't have assets
    /// for — symbols are a clean stand-in).
    private func glyph(for provider: AgentProvider) -> String {
        switch provider.backend {
        case .claudeCLI: return "terminal.fill"
        case .acp: return "cpu"
        }
    }
}

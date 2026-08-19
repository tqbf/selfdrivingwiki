import SwiftUI
import WikiFSEngine
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
/// The app is ACP-only: every provider shows its captured models (discovered
/// on first chat).
/// Selecting one threads it through `providerHints["acpSelectedModelId"]` →
/// `session/set_model`.
///
/// **Default = agent default by default:** a provider with no model selected
/// uses the agent's advertised default. Existing users see zero behavior change.
///
/// **Chat-scoped, not global:** selecting a row pins a provider + model to
/// THIS chat only (`ChatSummary.modelProviderId`/`.modelId`, or
/// `RemoteChatSession.pendingModelOverride` before the chat exists) —
/// outranking both the "chat" stage pin AND the global default provider. This
/// picker no longer writes the global default; see `chatModelOverride`.
struct ProviderSelector: View {
    /// The daemon-mirrored chat session — backs provider-config reads (the
    /// same shared config file the daemon reads at spawn) and holds the
    /// pending override for a not-yet-created (`.draft`) chat.
    var remoteSession: RemoteChatSession

    /// The client-side store — direct SQLite access to `chats`, used to read
    /// and write THIS chat's model override (`ChatSummary.modelProviderId`/
    /// `.modelId`). Same direct-write pattern as `renameChat`/`deleteChat`.
    var store: WikiStoreModel

    /// The selector's view of the config. Refreshed from the persisted file on
    /// appear + after each selection, so a change made in Settings is visible
    /// the next time the composer shows.
    @State private var config: AgentProvidersConfig

    /// Popover open state.
    @State private var isPresented = false

    /// The search query typed in the popover (empty = show all rows).
    @State private var searchText = ""

    /// The row currently under the pointer (for the hover highlight).
    @State private var hoveredRowID: String?

    /// Whether the trigger chip is currently under the pointer.
    @State private var isHovered = false

    @Environment(\.openSettings) private var openSettings

    init(remoteSession: RemoteChatSession, store: WikiStoreModel) {
        self.remoteSession = remoteSession
        self.store = store
        // The session owns an observable cached sidecar; this initializer
        // reads memory only, never decodes config during composer rendering.
        _config = State(initialValue: remoteSession.providersConfig())
    }

    /// The providers the selector surfaces (enabled only). The launcher's
    /// `selectedProvider()` never picks a disabled provider, so the list must
    /// agree — otherwise it could show a provider that won't actually be
    /// launched.
    private var pickable: [AgentProvider] {
        config.enabledProviders
    }

    /// THIS chat's model override, if any: `ChatSummary.modelProviderId`/
    /// `.modelId` for a persisted chat, or `RemoteChatSession.pendingModelOverride`
    /// for a `.draft` chat that has no row yet. `nil` = no override for this
    /// chat — `current` falls through to the stage pin / global default,
    /// unchanged from before this picker became chat-scoped.
    private var chatModelOverride: (providerId: ProviderID, modelId: ModelID?)? {
        switch remoteSession.chatID {
        case .draft:
            return remoteSession.pendingModelOverride
        case .chat(let pageID):
            guard let providerId = store.chats.first(where: { $0.id == pageID })?.modelProviderId else {
                return nil
            }
            return (providerId, store.chats.first(where: { $0.id == pageID })?.modelId)
        }
    }

    /// The effective provider for chat: THIS chat's own override when set +
    /// enabled (highest priority — see `chatModelOverride`), else the chat
    /// stage's pinned provider when set + enabled, else the global default
    /// (**Decision A**, `plans/agent-settings-tabs.md` §6.5, now extended with
    /// the per-chat tier). Selecting a row in the popover writes THIS chat's
    /// override (`selectRow`) — it no longer touches the global default.
    private var configuredThinkingValue: ChatConfigurationValueID? {
        switch remoteSession.chatID {
        case .draft:
            return remoteSession.pendingConfiguredThinkingOptionID
        case .chat(let chatID):
            return store.chats.first { $0.id == chatID }?.configuredThinkingOptionID
        }
    }

    private var current: AgentProvider {
        if let overrideProviderId = chatModelOverride?.providerId,
           let p = config.provider(id: overrideProviderId), p.enabled {
            return p
        }
        return config.provider(forStage: "chat")
    }

    var body: some View {
        // Compact trigger chip hugging the composer's left edge. The whole label
        // is the popover's hit target; Settings is reachable from the gear in the
        // popover header (no separate gear on the chip, which duplicated it).
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
        .onAppear { refresh() }
        // Keep in sync if a session flips (the composer is rebuilt when a chat
        // becomes live).
        .onChange(of: remoteSession.runState) { _, _ in refresh() }
        .onChange(of: remoteSession.providerConfiguration) { _, _ in refresh() }
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
        .frame(width: 300)
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
        ScrollView {
            VStack(spacing: 0) {
                ForEach(filteredRows) { row in
                    rowView(row)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: listHeight)
    }

    /// Hug the rows up to a cap: few models → a short popover with no wasted
    /// space; many → the list scrolls at the cap instead of growing tall.
    private var listHeight: CGFloat {
        let rowHeight: CGFloat = 40
        let count = max(filteredRows.count, 1)
        return min(CGFloat(count) * rowHeight + 8, 320)
    }

    /// One row (paseo model-menu style): glyph + a bold model name over a
    /// dimmer "Provider · description" subtitle + a checkmark when selected. The
    /// leading glyph is an SF Symbol per backend (terminal for Claude, cpu for
    /// ACP) since we have no brand assets.
    private func rowView(_ row: SelectorRow) -> some View {
        HStack(spacing: 8) {
            Button {
                selectRow(row)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: glyph(for: row.provider))
                        .frame(width: 16)
                        .foregroundStyle(Color.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(row.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if row.id == selectedRowID {
                        Image(systemName: "checkmark")
                            .imageScale(.small)
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Favorite star is a sibling button, so it cannot trigger row selection.
            if row.modelId != nil {
                Button {
                    toggleFavorite(row)
                } label: {
                    Image(systemName: row.isFavorite ? "star.fill" : "star")
                        .imageScale(.small)
                        .foregroundStyle(row.isFavorite ? Color.yellow : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.borderless)
                .help(row.isFavorite ? "Remove from favorites" : "Add to favorites")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredRowID == row.id ? Color.primary.opacity(0.08) : .clear)
                .padding(.horizontal, 4)
        )
        .onHover { inside in
            if inside { hoveredRowID = row.id } else if hoveredRowID == row.id { hoveredRowID = nil }
        }
    }

    /// Toggle + persist a model row's favorite state, refreshing local config so
    /// the star flips and the row re-sorts to (or from) the favorites group. Does
    /// NOT change the selection or close the popover.
    private func toggleFavorite(_ row: SelectorRow) {
        guard let modelId = row.modelId else { return }
        config = remoteSession.toggleFavoriteModel(modelId, forProvider: row.provider.id)
    }

    // MARK: - Row model (flat, searchable)

    /// One selectable (provider, model) pair in the flat list. `modelId == nil`
    /// is the synthetic "Default" row (paseo's `buildSyntheticDefaultRow`):
    /// selecting it picks the provider with no model → the agent's default.
    struct SelectorRow: Identifiable {
        let provider: AgentProvider
        let modelId: ModelID?
        let modelLabel: String
        /// The agent-advertised one-line description (paseo shows this as the
        /// row's dimmer second line). nil for the synthetic "Default" row.
        let modelDescription: String?
        /// Whether the user has starred this model (paseo per-row favorite).
        /// Always false for the synthetic "Default" row (not favoritable).
        let isFavorite: Bool
        let id: String
        /// All agent-advertised model ids represented by this row. A thinking
        /// effort model family may contain one id for each advertised effort.
        let modelIDs: Set<ModelID>

        /// Primary (bold) line — the model name, paseo-style (e.g. "Opus 4.8",
        /// "GLM-4.7", "Default").
        var title: String {
            modelLabel
        }

        /// Secondary (dimmer) line — the provider plus the agent-advertised
        /// description. For the "Default" row it notes no model is pinned; for a
        /// model row it appends the description when the agent supplied one.
        var subtitle: String {
            if modelId == nil {
                return "\(provider.label) · Agent default"
            }
            if let modelDescription, !modelDescription.isEmpty {
                return "\(provider.label) · \(modelDescription)"
            }
            return provider.label
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
                    modelDescription: nil,
                    isFavorite: false,
                    id: "\(provider.id.rawValue):default",
                    modelIDs: [])
            ]
            let selectedModelID = chatModelOverride?.providerId == provider.id
                ? chatModelOverride?.modelId
                : config.selectedModelId(forProvider: provider.id)
            let liveOption = provider.id == current.id ? remoteSession.thinkingOption : nil
            let liveCapability = liveOption.map {
                ThinkingCapabilityCatalog.observedACP($0.catalog)
            }
            let resolution = config.resolveThinkingCapability(
                providerID: provider.id,
                modelID: selectedModelID,
                configuredValueID: configuredThinkingValue,
                liveCapability: liveCapability,
                liveCurrentValueID: liveOption.map {
                    ChatConfigurationValueID(rawValue: $0.currentValue)
                })
            for family in Self.modelFamilies(
                from: models,
                resolution: resolution
            ) {
                let model = family.selectedModel
                rows.append(SelectorRow(
                    provider: provider,
                    modelId: model.modelId,
                    modelLabel: family.label,
                    modelDescription: model.description,
                    isFavorite: config.isFavoriteModel(model.modelId, forProvider: provider.id),
                    id: "\(provider.id.rawValue):\(family.id)",
                    modelIDs: Set(family.models.map(\.modelId))))
            }
            return rows
        }
    }

    /// The rows after applying the search filter, with favorites pinned to the
    /// top (paseo). Matches against the provider label + the model label
    /// (case-insensitive). Empty query = all rows. The favorites-first partition
    /// is stable, so ordering within each group is preserved.
    private var filteredRows: [SelectorRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = query.isEmpty ? flatRows : flatRows.filter { row in
            row.provider.label.lowercased().contains(query)
                || row.modelLabel.lowercased().contains(query)
        }
        // Favorites float to the top; everything else keeps its order.
        return matched.filter(\.isFavorite) + matched.filter { !$0.isFavorite }
    }

    /// The id of the row that matches the current selection (provider + model),
    /// or the provider's "default" row when no model is pinned. nil when nothing
    /// matches (no providers / provider not in list). When THIS chat has an
    /// override (`chatModelOverride`, and `current` resolved to that override's
    /// provider), the checkmark tracks the override's model — NOT the
    /// provider's global `selectedModelId` — so a chat pinned to a model the
    /// global default doesn't use still shows the right checkmark.
    private var selectedRowID: String? {
        if let override = chatModelOverride, override.providerId == current.id {
            if let modelId = override.modelId {
                return flatRows.first {
                    $0.provider.id == current.id && $0.modelIDs.contains(modelId)
                }?.id
            }
            return "\(current.id.rawValue):default"
        }
        let selectedModel = config.selectedModelId(forProvider: current.id)
        if let selectedModel {
            return flatRows.first {
                $0.provider.id == current.id && $0.modelIDs.contains(selectedModel)
            }?.id
        }
        return "\(current.id.rawValue):default"
    }

    // MARK: - Trigger

    /// The compact trigger: glyph + "Provider · model" + chevron. `.callout`
    /// type + primary fill so it reads as a real affordance under the
    /// composer. The model segment reflects the per-provider selection, or
    /// "default" when none is set. A subtle hover bubble (matching the
    /// popover-row idiom) signals clickability.
    private var trigger: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph(for: current))
                .foregroundStyle(Color.blue)
            Text(triggerLabel)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.primary)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    /// "Provider · model". For ACP providers the model is the user's selection
    /// (or "default" when none is selected); for Claude it's the selected
    /// alias (or "default").
    private var triggerLabel: String {
        "\(current.label) · \(currentModelSegment)"
    }

    private func thinkingResolution(
        for provider: AgentProvider,
        modelID: ModelID?
    ) -> ThinkingSelectionResolution {
        let liveOption = provider.id == current.id ? remoteSession.thinkingOption : nil
        return config.resolveThinkingCapability(
            providerID: provider.id,
            modelID: modelID,
            configuredValueID: configuredThinkingValue,
            liveCapability: liveOption.map {
                ThinkingCapabilityCatalog.observedACP($0.catalog)
            },
            liveCurrentValueID: liveOption.map {
                ChatConfigurationValueID(rawValue: $0.currentValue)
            })
    }

    /// The model text shown in the trigger for `current`: THIS chat's override
    /// model when one is active, else the provider's global selection (via
    /// `modelSegment(for:)`), else "default".
    private var currentModelSegment: String {
        if let override = chatModelOverride, override.providerId == current.id {
            guard let modelId = override.modelId else { return "default" }
            if let cached = config.cachedModels(forProvider: current.id)
                .first(where: { $0.modelId == modelId }) {
                return ThinkingEffortModelLabel.displayName(
                    for: cached.displayLabel,
                    advertisedEfforts: thinkingResolution(
                        for: current, modelID: modelId).capability?.displayAliases ?? [])
            }
            return modelId.rawValue
        }
        return modelSegment(for: current)
    }

    /// The model text for a provider's global selection: the user's
    /// selection, else "default". Only reached when this chat has no override
    /// (`currentModelSegment` short-circuits otherwise).
    private func modelSegment(for provider: AgentProvider) -> String {
        if let selected = config.selectedModelId(forProvider: provider.id) {
            // Use the cached friendly name when available.
            if let cached = config.cachedModels(forProvider: provider.id)
                .first(where: { $0.modelId == selected }) {
                return ThinkingEffortModelLabel.displayName(
                    for: cached.displayLabel,
                    advertisedEfforts: thinkingResolution(
                        for: provider, modelID: selected).capability?.displayAliases ?? [])
            }
            return selected.rawValue
        }
        return "default"
    }

    /// A single base-model choice with all of the agent's effort-specific
    /// iterations. `selectedModel` is the variant matching the active
    /// Thinking control, falling back to the first advertised variant.
    struct ModelFamily: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let models: [CachedModelInfo]
        let selectedModel: CachedModelInfo
    }

    /// Collapse only exact model IDs declared by a normalized model-variant
    /// mechanism. Display names never define capability or family membership.
    nonisolated static func modelFamilies(
        from models: [CachedModelInfo],
        resolution: ThinkingSelectionResolution
    ) -> [ModelFamily] {
        guard case .modelVariants(let mapping) = resolution.mechanism,
              !mapping.isEmpty else {
            return models.map { model in
                ModelFamily(
                    id: "model:\(model.modelId.rawValue)",
                    label: model.displayLabel,
                    models: [model],
                    selectedModel: model)
            }
        }
        let mappedIDs = Set(mapping.values)
        let variants = models.filter { mappedIDs.contains($0.modelId) }
        let selectedID = resolution.effectiveValueID.flatMap { mapping[$0] }
        let selected = selectedID.flatMap { id in variants.first { $0.modelId == id } }
            ?? variants.first
        var result: [ModelFamily] = []
        if let selected, let first = variants.first {
            let label = ThinkingEffortModelLabel.displayName(
                for: first.displayLabel,
                advertisedEfforts: resolution.capability?.displayAliases ?? [])
            result.append(ModelFamily(
                id: "thinking:\(first.modelId.rawValue)",
                label: label,
                models: variants,
                selectedModel: selected))
        }
        result.append(contentsOf: models.filter { !mappedIDs.contains($0.modelId) }.map { model in
            ModelFamily(
                id: "model:\(model.modelId.rawValue)",
                label: model.displayLabel,
                models: [model],
                selectedModel: model)
        })
        return result
    }

    private var defaultHelpText: String {
        "Provider and model for this chat"
    }

    // MARK: - Actions

    /// Selecting a row parses its id back into (provider, modelId) and persists
    /// both as THIS CHAT's override, then closes the popover. Mirrors paseo's
    /// "choosing a model implies choosing its provider" — but scoped to the
    /// chat, not the global default (see the type doc comment). For a `.draft`
    /// chat (no row yet), stashes the pick on `remoteSession` for
    /// `ChatDetailView.submitMessage` to seed at creation.
    private func selectRow(_ row: SelectorRow) {
        let provider = row.provider
        let modelId = row.modelId
        DebugLog.agent("ProviderSelector.selectRow: provider=\(provider.id.rawValue) modelId=\(modelId?.rawValue ?? "nil") (nil=Default/agent-default)")
        switch remoteSession.chatID {
        case .draft:
            remoteSession.pendingModelOverride = (provider.id, modelId)
        case .chat(let pageID):
            let summary = store.chats.first { $0.id == pageID }
            let configured = summary?.configuredThinkingOptionID
            let resolved = config.resolveThinkingCapability(
                providerID: provider.id,
                modelID: modelId,
                configuredValueID: configured,
                priorEffectiveValueID: summary?.effectiveThinkingOptionID)
            store.updateChatModelAndThinkingSelection(
                chatID: pageID,
                providerID: provider.id,
                modelID: modelId,
                configuredThinkingID: configured,
                effectiveThinkingID: resolved.effectiveValueID)
        }
        isPresented = false
        searchText = ""
    }

    private func refresh() {
        config = remoteSession.providersConfig()
    }

    // MARK: - Glyphs

    /// SF Symbol per provider. Every provider is ACP; they share a CPU glyph
    /// (paseo uses per-provider brand glyphs we don't have assets for —
    /// symbols are a clean stand-in).
    private func glyph(for provider: AgentProvider) -> String {
        "cpu"
    }
}

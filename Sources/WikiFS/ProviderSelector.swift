import SwiftUI
import WikiFSCore

/// A compact provider + model selector for the chat composer, modeled on
/// paseo's `combined-model-selector` (translated to native macOS). It shows the
/// current **provider and model** — an SF Symbol glyph + "Provider · model" +
/// a chevron — and opens a drill-down: list the enabled providers, each as a
/// submenu of its cached models (with a checkmark on the selected one); pick a
/// model to set it as the provider's persisted selection. The top-level menu
/// item per provider also lets you switch the default provider (paseo's
/// provider→model two-step, collapsed into a native `Menu` submenu).
///
/// **Model discovery (#329):** models are captured from the agent's own
/// `session/new` response on first chat and cached per-provider in
/// `AgentProvidersConfig.providerModels`. If a provider has no cached models
/// yet, its submenu shows a muted "models discovered on first chat" hint (v1
/// capture-from-session; on-demand probing is a later enhancement).
///
/// **Claude (CLI):** `ClaudeCLIBackend` has no ACP model discovery, so the
/// Claude provider's submenu shows the configured `modelOverride`
/// (display-only for v1) instead of a model list. The default = Claude path
/// is unchanged.
///
/// **Selection = agent default by default:** a provider with no model selected
/// uses the agent's advertised default (no `session/set_model`). Existing
/// users see zero behavior change.
///
/// Small + unobtrusive: a leading-aligned bar below the text field, `.caption`
/// type, secondary label color. It reads the providers list + the cached models
/// + the current selection from the launcher (`providersConfig()`) and mutates
/// the default provider through `launcher.setDefaultProvider(id:)` and the
/// per-provider model selection through `launcher.setSelectedModel(_:forProvider:)`,
/// then refreshes its own state. The gear affordance opens Settings.
struct ProviderSelector: View {
    @Bindable var launcher: AgentLauncher

    /// The selector's view of the config. Refreshed from the persisted file on
    /// appear + after each selection, so a change made in Settings is visible
    /// the next time the composer shows.
    @State private var config: AgentProvidersConfig

    @Environment(\.openSettings) private var openSettings

    init(launcher: AgentLauncher) {
        self.launcher = launcher
        // Seed off-main via the launcher's accessor so the composer never
        // blocks on file I/O at first paint.
        _config = State(initialValue: launcher.providersConfig())
    }

    /// The providers the selector surfaces (enabled only). The launcher's
    /// `selectedProvider()` never picks a disabled provider, so the menu must
    /// agree — otherwise the menu could show a provider that won't actually be
    /// launched.
    private var pickable: [AgentProvider] {
        config.enabledProviders
    }

    private var current: AgentProvider {
        config.selectedProvider()
    }

    var body: some View {
        // Only the live chat / draft composer should show it, but keep the
        // surface itself lightweight: a single menu + a gear. Leading-aligned
        // so it hugs the composer's left edge (paseo places the trigger at the
        // composer's start).
        HStack(spacing: 4) {
            Menu {
                providerMenuContent
            } label: {
                trigger
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden) // we draw our own chevron (paseo-style)
            .fixedSize()
            .help(defaultHelpText)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Open Provider settings")
        }
        .onAppear { refresh() }
        // Keep in sync if a session flips (the composer is rebuilt when a chat
        // becomes live). Cheap: it's a single file read.
        .onChange(of: launcher.activeChatID) { _, _ in refresh() }
    }

    // MARK: - Menu content (provider → model drill-down)

    /// The drill-down: one entry per enabled provider. Each provider is a
    /// `Menu` whose label is the provider name (and a checkmark when it's the
    /// default); its submenu lists the provider's cached models with a checkmark
    /// on the selected one. Picking a model persists the per-provider selection
    /// AND sets that provider as the default (paseo's two-step: choosing a model
    /// implies choosing its provider).
    @ViewBuilder private var providerMenuContent: some View {
        ForEach(pickable) { provider in
            Menu {
                providerModelSubmenu(for: provider)
            } label: {
                if provider.id == current.id {
                    Label(provider.label, systemImage: "checkmark")
                } else {
                    Label(provider.label, systemImage: glyph(for: provider))
                }
            }
        }
        Divider()
        Button("Manage Providers…") { openSettings() }
    }

    /// The model submenu for one provider. For ACP providers with cached
    /// models, lists each model with a checkmark on the selection. For Claude
    /// (no discovery) shows the model override display-only. For an ACP
    /// provider with no cached models yet, shows the discovery hint.
    @ViewBuilder
    private func providerModelSubmenu(for provider: AgentProvider) -> some View {
        let models = config.cachedModels(forProvider: provider.id)
        switch provider.backend {
        case .claudeCLI:
            claudeModelSubmenu(for: provider)
        case .acp:
            if models.isEmpty {
                // No models discovered yet — show the v1 hint (on-demand probing
                // is a later enhancement). A disabled section header conveys
                // "not yet, but will populate" without an actionable item.
                Section(provider.label) {
                    Text("Models discovered on first chat")
                        .foregroundStyle(.tertiary)
                }
            } else {
                acpModelSubmenu(for: provider, models: models)
            }
        }
    }

    /// ACP provider submenu: a "Default" row (clears the selection → agent's
    /// advertised default) then each cached model with a checkmark on the
    /// selected one. Picking a model persists the selection and makes this the
    /// default provider.
    @ViewBuilder
    private func acpModelSubmenu(for provider: AgentProvider, models: [CachedModelInfo]) -> some View {
        let selected = config.selectedModelId(forProvider: provider.id)
        Button {
            selectModel(nil, for: provider)
        } label: {
            if selected == nil {
                Label("Default", systemImage: "checkmark")
            } else {
                Text("Default")
            }
        }
        ForEach(models) { model in
            Button {
                selectModel(model.modelId, for: provider)
            } label: {
                if selected == model.modelId {
                    Label(model.displayLabel, systemImage: "checkmark")
                } else {
                    Text(model.displayLabel)
                }
            }
        }
    }

    /// Claude (CLI) submenu: display-only. `ClaudeCLIBackend` has no ACP model
    /// discovery, so we surface the configured `modelOverride` (blank = the
    /// per-op alias default) as a read-only label. v1 is display-only; the
    /// override is edited in Settings.
    @ViewBuilder
    private func claudeModelSubmenu(for provider: AgentProvider) -> some View {
        let override = claudeModelOverride()
        if override.isEmpty {
            Text("Model: default (per-op alias)")
                .foregroundStyle(.tertiary)
        } else {
            Text("Model: \(override)")
                .foregroundStyle(.tertiary)
        }
    }

    /// The configured Claude CLI model override, if any. Loaded fresh so a
    /// Settings change is visible next time the menu opens.
    private func claudeModelOverride() -> String {
        let dir = (try? DatabaseLocation.appGroupContainerDirectory())
            ?? FileManager.default.temporaryDirectory
        let override = AgentCommandConfig.load(from: dir).modelOverride
        return override.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The compact trigger: glyph + "Provider · model" + chevron. `.caption`
    /// type + secondary fill so it reads as an auxiliary affordance under the
    /// composer, not a primary control. The whole label is the menu's hit
    /// target. The model segment reflects the per-provider selection, or
    /// "default" when none is set.
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
    /// (or the cached current/default when none is selected); for Claude it's
    /// the model override (or "default").
    private var triggerLabel: String {
        let providerLabel = current.label
        let model = modelSegment(for: current)
        return "\(providerLabel) · \(model)"
    }

    /// The model text shown in the trigger for a provider. For ACP: the user's
    /// selection, else the first cached model's label, else "default". For
    /// Claude: the override, else "default".
    private func modelSegment(for provider: AgentProvider) -> String {
        switch provider.backend {
        case .claudeCLI:
            let override = claudeModelOverride()
            return override.isEmpty ? "default" : override
        case .acp:
            if let selected = config.selectedModelId(forProvider: provider.id) {
                // Use the cached friendly name when available.
                if let cached = config.cachedModels(forProvider: provider.id)
                    .first(where: { $0.modelId == selected }) {
                    return cached.displayLabel
                }
                return selected
            }
            let cached = config.cachedModels(forProvider: provider.id)
            return cached.first?.displayLabel ?? "default"
        }
    }

    private var defaultHelpText: String {
        if current.backend == .acp {
            return "Provider and model for new chats"
        }
        return "Default provider for new chats"
    }

    // MARK: - Actions

    /// Selecting a model (or clearing to nil) persists the per-provider
    /// selection AND makes its provider the default, so the next chat uses
    /// both. Mirrors paseo's "choosing a model implies choosing its provider".
    /// Done atomically (one load→mutate→save) to avoid a race between two
    /// separate writes.
    private func selectModel(_ modelId: String?, for provider: AgentProvider) {
        DebugLog.agent("ProviderSelector.selectModel: provider=\(provider.id) modelId=\(modelId ?? "nil") (nil=Default/agent-default)") // TEMP DEBUG
        config = launcher.setSelectedModelAndDefault(modelId, provider: provider)
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

import SwiftUI
import WikiFSCore

/// A compact provider selector for the chat composer (modeled on paseo's
/// `combined-model-selector` trigger, translated to native macOS). It shows the
/// current default provider — an SF Symbol glyph + label + a chevron — and
/// opens a menu of the **enabled** providers. Picking one sets it as the
/// persisted default (`AgentProvidersConfig.selectedProvider()`), so the next
/// chat session uses the chosen backend via the launcher's
/// `resolveSelectedProvider` (no launcher change needed).
///
/// v1 is **provider-only** (no model drill-down): selfdrivingwiki does not yet
/// surface per-agent models. The optional gear affordance opens Settings → the
/// user manages commands/keys/enable there.
///
/// Small + unobtrusive: a leading-aligned bar below the text field, `.caption`
/// type, tertiary label color. It reads the providers list + the current
/// default from the launcher (`providersConfig()`) and mutates the default
/// through `launcher.setDefaultProvider(id:)`, then refreshes its own state.
/// State mirrors `AgentProvidersSettingsView`'s load/mutate path (file I/O
/// lives in `AgentProvidersConfig.save`; the launcher does the container
/// resolution).
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
        config.defaultProvider
    }

    var body: some View {
        // Only the live chat / draft composer should show it, but keep the
        // surface itself lightweight: a single menu + a gear. Leading-aligned
        // so it hugs the composer's left edge (paseo places the trigger at the
        // composer's start).
        HStack(spacing: 4) {
            Menu {
                ForEach(pickable) { provider in
                    Button {
                        select(provider.id)
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
            } label: {
                trigger
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden) // we draw our own chevron (paseo-style)
            .fixedSize()
            .help("Default provider for new chats")

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

    /// The compact trigger: glyph + current label + chevron. `.caption` type +
    /// secondary fill so it reads as an auxiliary affordance under the composer,
    /// not a primary control. The whole label is the menu's hit target.
    private var trigger: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph(for: current))
                .foregroundStyle(current.backend == .claudeCLI ? Color.purple : Color.blue)
            Text(current.label)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func select(_ id: String) {
        // Set + persist through the launcher so the container resolution is
        // shared with `resolveSelectedProvider`. The returned config becomes
        // the new bound state (single-default invariant already enforced).
        config = launcher.setDefaultProvider(id: id)
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

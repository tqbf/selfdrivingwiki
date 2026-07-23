import SwiftUI
import WikiFSEngine

/// #566: The "Thinking" dropdown for the chat composer toolbar.
///
/// Surfaces the agent's `thought_level` config option (high/medium/low) so the
/// user can change how hard the agent reasons, mid-session. Capability-gated:
/// the view renders nothing when `launcher.thinkingOption` is `nil` (agent
/// advertises no `thought_level` — older agents, or those that don't switch
/// model variants). This is the agent-dependent hide rule from the issue.
///
/// **UI shape:** a compact borderless chip next to `ProviderSelector`, showing
/// a brain glyph + the current level + a chevron. Tapping opens a native
/// `Menu` (the level list is short — 2–4 fixed entries — so the
/// ProviderSelector-style search popover would be overkill and less native).
/// A checkmark marks the active level. Selecting one calls
/// `launcher.setThinkingEffort(_:)`, which optimistically flips the chip and
/// fires `session/set_config_option`; a `config_option_update` confirms it.
///
/// Mirrors `ProviderSelector`'s trigger styling (.callout font, secondary
/// foreground, tertiary chevron) so the two chips read as siblings.
struct ThinkingEffortSelector: View {
    /// The daemon-mirrored chat session. `thinkingOption` is mirrored from the
    /// daemon's launcher via chat-state envelopes; `setThinkingEffort` flips
    /// the chip locally (daemon-side apply is deferred — no chat-config XPC
    /// method in Phase C4). Replaces the chat `AgentLauncher` binding.
    var remoteSession: RemoteChatSession

    var body: some View {
        // Capability gate: render nothing when the agent advertises no
        // `thought_level`. This keeps the toolbar uncluttered for agents that
        // don't support thinking-effort switching.
        if let option = remoteSession.thinkingOption {
            Menu {
                ForEach(option.choices) { choice in
                    Button {
                        remoteSession.setThinkingEffort(choice.value)
                    } label: {
                        if choice.value == option.currentValue {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                trigger(option: option)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Thinking effort — how hard the agent reasons before answering")
        }
    }

    /// The compact chip: brain glyph + current level + chevron. Styled to sit
    /// beside `ProviderSelector` as a sibling secondary control.
    private func trigger(option: ThinkingEffortOption) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "brain.head.profile")
                .foregroundStyle(Color.purple)
            Text(option.currentValue)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }
}

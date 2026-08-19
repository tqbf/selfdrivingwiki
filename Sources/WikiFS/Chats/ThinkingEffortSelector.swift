import SwiftUI
import WikiFSEngine
import WikiFSCore

struct ThinkingEffortPresentation: Equatable, Sendable {
    let choices: [ThinkingOptionCatalogChoice]
    let effectiveValueID: ChatConfigurationValueID?
    let effectiveLabel: String
    let configOptionID: ChatConfigurationOptionID?
    let modelIDByValueID: [ChatConfigurationValueID: ModelID]
    let isUsingFallback: Bool
    let shouldRender: Bool

    static func resolve(
        config: AgentProvidersConfig,
        providerID: ProviderID?,
        modelID: ModelID?,
        configuredID: ChatConfigurationValueID?,
        liveOption: ThinkingEffortOption?
    ) -> Self {
        let liveCapability = liveOption.map {
            ThinkingCapabilityCatalog.observedACP($0.catalog)
        }
        let liveID = liveOption.map { ChatConfigurationValueID(rawValue: $0.currentValue) }
        let resolution = config.resolveThinkingCapability(
            chatOverrideProviderID: providerID,
            chatOverrideModelID: modelID,
            configuredValueID: configuredID,
            liveCapability: liveCapability,
            liveCurrentValueID: liveID)
        return from(resolution)
    }

    static func from(_ resolution: ThinkingSelectionResolution) -> Self {
        let label = resolution.choices.first { $0.id == resolution.effectiveValueID }?.label
            ?? resolution.effectiveValueID?.rawValue
            ?? "Thinking"
        return Self(
            choices: resolution.choices,
            effectiveValueID: resolution.effectiveValueID,
            effectiveLabel: label,
            configOptionID: resolution.configOptionID,
            modelIDByValueID: resolution.modelIDByValueID,
            isUsingFallback: resolution.isUsingFallback,
            shouldRender: resolution.shouldRenderSelector)
    }
}

/// Compact catalog-driven Thinking menu for draft, idle, restored, and live chats.
/// The provider catalog owns choices/defaults; the chat owns configured/effective
/// IDs. Live session metadata is an authoritative overlay, not a visibility gate.
struct ThinkingEffortSelector: View {
    var remoteSession: RemoteChatSession
    var store: WikiStoreModel

    private var chatSummary: ChatSummary? {
        guard case .chat(let chatID) = remoteSession.chatID else { return nil }
        return store.chats.first { $0.id == chatID }
    }

    private var modelOverride: (ProviderID?, ModelID?) {
        if let chatSummary {
            return (chatSummary.modelProviderId, chatSummary.modelId)
        }
        return (remoteSession.pendingModelOverride?.providerId,
                remoteSession.pendingModelOverride?.modelId)
    }

    private var configuredID: ChatConfigurationValueID? {
        chatSummary?.configuredThinkingOptionID
            ?? remoteSession.pendingConfiguredThinkingOptionID
    }

    private var presentation: ThinkingEffortPresentation {
        ThinkingEffortPresentation.resolve(
            config: remoteSession.providerConfiguration,
            providerID: modelOverride.0,
            modelID: modelOverride.1,
            configuredID: configuredID,
            liveOption: remoteSession.thinkingOption)
    }

    var body: some View {
        let state = presentation
        if state.shouldRender {
            Menu {
                ForEach(state.choices) { choice in
                    Button {
                        select(choice.id, state: state)
                    } label: {
                        if choice.id == state.effectiveValueID {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                trigger(label: state.effectiveLabel, isUsingFallback: state.isUsingFallback)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(state.isUsingFallback
                ? "The configured thinking effort is unavailable. Using \(state.effectiveLabel)."
                : "Thinking effort — how hard the agent reasons before answering")
            .accessibilityLabel("Thinking effort")
            .accessibilityValue(state.effectiveLabel)
        }
    }

    private func select(
        _ valueID: ChatConfigurationValueID,
        state: ThinkingEffortPresentation
    ) {
        let targetModelID = state.modelIDByValueID[valueID]
        switch remoteSession.chatID {
        case .draft:
            remoteSession.pendingConfiguredThinkingOptionID = valueID
            if let targetModelID, let providerID = modelOverride.0 {
                remoteSession.pendingModelOverride = (providerID, targetModelID)
            }
        case .chat(let chatID):
            store.updateChatModelAndThinkingSelection(
                chatID: chatID,
                providerID: chatSummary?.modelProviderId,
                modelID: targetModelID ?? chatSummary?.modelId,
                configuredThinkingID: valueID,
                effectiveThinkingID: targetModelID != nil
                    ? valueID
                    : (remoteSession.runState.isLive
                        ? chatSummary?.effectiveThinkingOptionID
                        : valueID))
        }
        if targetModelID == nil, remoteSession.runState.isLive, state.configOptionID != nil {
            remoteSession.setThinkingEffort(
                valueID,
                configOptionID: state.configOptionID)
        }
    }

    private func trigger(label: String, isUsingFallback: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "brain.head.profile")
                .foregroundStyle(Color.purple)
            Text(label)
                .foregroundStyle(.secondary)
            if isUsingFallback {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
            }
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }
}

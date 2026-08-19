// pattern: Imperative Shell

import AppKit
import SwiftUI
import WikiFSCore

struct ChatComposerPaneProps {
    let composer: ChatDetailPresentation.Composer
    let queuedMessages: [PendingQueuedMessage]
    let autoFocus: Bool
    let attachments: [ChatAttachment]
    let remoteSession: RemoteChatSession
    let store: WikiStoreModel
    let composerHeight: Binding<CGFloat>
    let composerFont: NSFont
    let permissionModeRaw: Binding<String>
    let autocomplete: ComposerTextView.AutocompleteHooks?
    let onSubmit: () -> Void
    let onQueue: () -> Void
    let onStop: () -> Void
    let onRecallQueued: (() -> Void)?
    let onEditQueuedMessage: (Int) -> Void
    let onRemoveQueuedMessage: (Int) -> Void
    let onAddAttachment: (ChatAttachment) -> Void
    let onRemoveAttachment: (ChatAttachment) -> Void
}

struct ChatComposerPaneView: View {
    let props: ChatComposerPaneProps

    var body: some View {
        VStack(spacing: 4) {
            if !props.queuedMessages.isEmpty {
                VStack(spacing: 3) {
                    ForEach(Array(props.queuedMessages.enumerated()), id: \.element.id) { index, pending in
                        queuedMessageRow(pending, isFirst: index == 0, index: index)
                    }
                }
            }
            composerBox
            if let caption = props.composer.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: props.queuedMessages)
    }

    private var composerBox: some View {
        @Bindable var bindableStore = props.store
        return VStack(alignment: .leading, spacing: ChatMetrics.composerRowSpacing) {
                if !props.attachments.isEmpty {
                    attachmentChips
                }
                ComposerTextView(
                    text: $bindableStore.draftChatMessage,
                    isEditable: props.composer.isEnabled,
                    font: props.composerFont,
                    onSubmit: props.onSubmit,
                    measuredHeight: props.composerHeight,
                    autoFocus: props.autoFocus,
                    autocomplete: props.autocomplete,
                    onRecallQueued: props.onRecallQueued
                )
                .frame(height: props.composerHeight.wrappedValue)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    if bindableStore.draftChatMessage.isEmpty {
                        Text("Ask a question, or ask to update the wiki…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .padding(.vertical, ComposerTextView.Metrics.verticalInsetPerSide)
                    }
                }

                composerToolbar
            }
            .padding(.horizontal, ChatMetrics.composerHorizontalPadding)
            .padding(.top, ChatMetrics.composerTopPadding)
            .padding(.bottom, ChatMetrics.composerBottomPadding)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: ChatMetrics.composerCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ChatMetrics.composerCornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.9), lineWidth: 1.5)
            }
            .shadow(color: Color.black.opacity(0.10), radius: 20, x: 0, y: 8)
            .frame(maxWidth: .infinity)
            .dropDestination(for: SidebarDragPayloadList.self) { lists, _ in
                let payloads = lists.flatMap(\.items)
                for payload in payloads {
                    props.onAddAttachment(ChatAttachment(payload: payload, store: props.store))
                }
                return !payloads.isEmpty
            }
        }
    

    private var composerToolbar: some View {
        HStack(spacing: 10) {
            AddContextPicker(store: props.store) { payload in
                props.onAddAttachment(ChatAttachment(payload: payload, store: props.store))
            }
            ProviderSelector(remoteSession: props.remoteSession, store: props.store)
            ThinkingEffortSelector(remoteSession: props.remoteSession, store: props.store)
            PermissionModeSelector(rawValue: props.permissionModeRaw)
            Spacer(minLength: 0)
            if props.composer.showsStopButton {
                if props.composer.showsQueueButton && hasDraftText {
                    queueButton
                }
                stopButton
            } else if hasDraftText {
                sendButton(active: props.composer.canSend)
            }
        }
        .frame(minHeight: ChatMetrics.sendButtonSize)
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(props.attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: attachment.systemImage)
                            .font(.caption2)
                        Text(attachment.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            props.onRemoveAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var hasDraftText: Bool {
        !props.store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var queueButton: some View {
        Button(action: props.onQueue) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: ChatMetrics.sendButtonSize, height: ChatMetrics.sendButtonSize)
                .background(Color.accentColor.opacity(0.9), in: Circle())
        }
        .buttonStyle(.borderless)
        .disabled(!hasDraftText)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Queue for when the response finishes")
    }

    private var stopButton: some View {
        Button(action: props.onStop) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: ChatMetrics.sendButtonSize, height: ChatMetrics.sendButtonSize)
                .background(Color.red.opacity(0.85), in: Circle())
        }
        .buttonStyle(.borderless)
        .help("Stop the current response")
    }

    private func sendButton(active: Bool) -> some View {
        Button(action: props.onSubmit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: ChatMetrics.sendButtonSize, height: ChatMetrics.sendButtonSize)
                .background(active ? Color.green : Color(nsColor: .quaternaryLabelColor).opacity(0.4), in: Circle())
        }
        .buttonStyle(.borderless)
        .disabled(!active)
        .keyboardShortcut(.return, modifiers: .command)
        .help(props.composer.sendButtonTitle)
    }

    private func queuedMessageRow(_ pending: PendingQueuedMessage, isFirst: Bool, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if isFirst {
                Text("Next:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .bold()
            } else {
                Text("#\(index + 1):")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(pending.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                props.onEditQueuedMessage(index)
            } label: {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Edit this queued message")
            .disabled(hasDraftText)
            Button {
                props.onRemoveQueuedMessage(index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel this queued message")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10), in: Capsule())
        .transition(.opacity)
    }
}

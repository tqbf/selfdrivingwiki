#if os(macOS)
import SwiftUI
import WikiFSTypes

// pattern: Imperative Shell

/// The visual and accessibility state for one presentation control.
///
/// Keeping this projection pure makes Source, Rendered, and Split semantics
/// consistent for both the native control treatment and VoiceOver.
struct RendererPresentationControlState: Sendable, Equatable {
    let presentation: RendererSourcePresentationMode
    let selectedPresentation: RendererSourcePresentationMode

    var isSelected: Bool { presentation == selectedPresentation }
    var accessibilityValue: String { isSelected ? "Selected" : "Not selected" }
}

/// Generic native renderer host. It owns presentation controls and keeps Source
/// visible whenever matching or rendering cannot provide a rendered pane.
struct RendererHostView<Source: View, Rendered: View>: View {
    @Binding var state: RendererPresentationState
    let descriptors: [RendererDescriptor]
    let showsControls: Bool
    let source: () -> Source
    let rendered: (RendererDescriptor) -> Rendered?
    let onRendererSelected: (RendererReference) -> Void
    let onSourceSelected: () -> Void
    let onPresentationSelected: (RendererPresentationState.Selection) -> Void
    let onFallback: (String) -> Void

    private var selectedDescriptor: RendererDescriptor? {
        guard let reference = state.pinnedRenderer else { return nil }
        return descriptors.first { $0.reference == reference }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsControls && !descriptors.isEmpty {
                controls
            }
            Group {
                if state.selection == .source, let fallbackReason = state.fallbackReason {
                    fallbackNotice(reason: fallbackReason)
                }
                switch state.selection {
                case .source:
                    source()
                case .rendered:
                    if let selectedDescriptor {
                        if let renderedContent = rendered(selectedDescriptor) {
                            renderedContent
                        } else {
                            fallbackWithSource(reason: "The selected renderer could not be loaded.")
                        }
                    } else {
                        fallbackWithSource(reason: "The selected renderer is unavailable.")
                    }
                case .split:
                    if RendererPresentationLayout.supportsSplit(detailWidth: PageEditorMetrics.detailMinWidth) {
                        HSplitView {
                            source().frame(minWidth: RendererPresentationLayout.minimumSourcePaneWidth)
                            if let selectedDescriptor {
                                if let renderedContent = rendered(selectedDescriptor) {
                                    renderedContent.frame(minWidth: RendererPresentationLayout.minimumRenderedPaneWidth)
                                } else {
                                    fallbackPane(reason: "The selected renderer could not be loaded.")
                                }
                            } else {
                                fallbackPane(reason: "The selected renderer is unavailable.")
                            }
                        }
                    } else {
                        fallbackWithSource(reason: "The detail pane is too narrow for Split view.")
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            presentationControl(.source) {
                Button("Source") {
                    state.selectSource()
                    onSourceSelected()
                    onPresentationSelected(.source)
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .accessibilityLabel("Show source")
            }
            presentationControl(.rendered) {
                Menu("Rendered") {
                    ForEach(descriptors, id: \.reference) { descriptor in
                        Button(descriptor.displayName) {
                            state.selectRendered(descriptor.reference)
                            onRendererSelected(descriptor.reference)
                            onPresentationSelected(.rendered)
                        }
                    }
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .accessibilityLabel("Show rendered content")
            }
            presentationControl(.split) {
                Button("Split") {
                    if let reference = Self.splitRendererReference(
                        pinnedRenderer: state.pinnedRenderer,
                        availableRendererReferences: descriptors.map(\.reference)
                    ) {
                        state.selectSplit(reference)
                        onRendererSelected(reference)
                        onPresentationSelected(.split)
                    }
                }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .accessibilityLabel("Show source and rendered content")
                .disabled(descriptors.isEmpty)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func presentationControl<Content: View>(
        _ presentation: RendererSourcePresentationMode,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let controlState = RendererPresentationControlState(
            presentation: presentation,
            selectedPresentation: state.selection)
        if controlState.isSelected {
            content()
                .buttonStyle(.borderedProminent)
                .accessibilityValue(controlState.accessibilityValue)
                .accessibilityAddTraits(.isSelected)
        } else {
            content()
                .buttonStyle(.bordered)
                .accessibilityValue(controlState.accessibilityValue)
        }
    }

    /// A pin only belongs to the descriptor snapshot that supplied it. If the
    /// snapshot changed, Split must use a descriptor that is available now.
    static func splitRendererReference(
        pinnedRenderer: RendererReference?,
        availableRendererReferences: [RendererReference]
    ) -> RendererReference? {
        guard let pinnedRenderer, availableRendererReferences.contains(pinnedRenderer) else {
            return availableRendererReferences.first
        }
        return pinnedRenderer
    }

    @ViewBuilder
    private func fallbackWithSource(reason: String) -> some View {
        source()
        .onAppear { selectSourceAfterFallback(reason) }
    }

    private func fallbackNotice(reason: String) -> some View {
        Text(reason)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func fallbackPane(reason: String) -> some View {
        ContentUnavailableView {
            Label("Renderer Unavailable", systemImage: "rectangle.slash")
        } description: {
            Text(reason)
        }
        .frame(minWidth: RendererPresentationLayout.minimumRenderedPaneWidth, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectSourceAfterFallback(reason)
        }
    }

    private func selectSourceAfterFallback(_ reason: String) {
        // `onAppear` runs after the update pass, so this is not an AppKit
        // representable update seam. Defer one turn to avoid a synchronous
        // state mutation while SwiftUI is constructing the fallback tree.
        Task { @MainActor in
            guard state.fallbackReason == nil else { return }
            state.selectFallback(reason: reason)
            onFallback(reason)
        }
    }
}
#endif

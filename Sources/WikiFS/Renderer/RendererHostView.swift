#if os(macOS)
import SwiftUI
import WikiFSTypes

// pattern: Imperative Shell

/// Generic native renderer host. It owns presentation controls and keeps Source
/// visible whenever matching or rendering cannot provide a rendered pane.
struct RendererHostView<Source: View, Rendered: View>: View {
    @Binding var state: RendererPresentationState
    let descriptors: [RendererDescriptor]
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
            if !descriptors.isEmpty {
                controls
            }
            Group {
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
                    HSplitView {
                        source().frame(minWidth: RendererHostMetrics.minimumSourcePaneWidth)
                        if let selectedDescriptor {
                            if let renderedContent = rendered(selectedDescriptor) {
                                renderedContent.frame(minWidth: RendererHostMetrics.minimumRenderedPaneWidth)
                            } else {
                                fallbackPane(reason: "The selected renderer could not be loaded.")
                            }
                        } else {
                            fallbackPane(reason: "The selected renderer is unavailable.")
                        }
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Source") {
                state.selectSource()
                onSourceSelected()
                onPresentationSelected(.source)
            }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .accessibilityLabel("Show source")
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
            Button("Split") {
                if let reference = state.pinnedRenderer ?? descriptors.first?.reference {
                    state.selectSplit(reference)
                    onRendererSelected(reference)
                    onPresentationSelected(.split)
                }
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
            .accessibilityLabel("Show source and rendered content")
            .disabled(descriptors.isEmpty)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func fallbackWithSource(reason: String) -> some View {
        VStack(spacing: 8) {
            Text(reason).font(.callout).foregroundStyle(.secondary)
            source()
        }
        .onAppear { selectSourceAfterFallback(reason) }
    }

    @ViewBuilder
    private func fallbackPane(reason: String) -> some View {
        ContentUnavailableView {
            Label("Renderer Unavailable", systemImage: "rectangle.slash")
        } description: {
            Text(reason)
        }
        .frame(minWidth: RendererHostMetrics.minimumRenderedPaneWidth, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectSourceAfterFallback(reason)
        }
    }

    private func selectSourceAfterFallback(_ reason: String) {
        onFallback(reason)
        // `onAppear` runs after the update pass, so this is not an AppKit
        // representable update seam. Defer one turn to avoid a synchronous
        // state mutation while SwiftUI is constructing the fallback tree.
        Task { @MainActor in state.selectSource() }
    }
}

private enum RendererHostMetrics {
    static let minimumSourcePaneWidth: CGFloat = 280
    static let minimumRenderedPaneWidth: CGFloat = 280
}
#endif

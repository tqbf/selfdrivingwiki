#if os(macOS)
import SwiftUI
import WikiFSTypes

// pattern: Imperative Shell

/// Generic native renderer host. It owns presentation tabs and keeps Source
/// visible whenever matching or rendering cannot provide a rendered pane.
struct RendererHostView<Source: View, Rendered: View>: View {
    private enum Tab: Hashable {
        case source
        case renderer(RendererReference)
    }
    @Binding var state: RendererPresentationState
    let descriptors: [RendererDescriptor]
    let showsControls: Bool
    let source: () -> Source
    let rendered: (RendererDescriptor) -> Rendered?
    let onRendererSelected: (RendererReference) -> Void
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
                        fallbackWithSource(reason: RendererPresentationState.unavailableFallbackMessage)
                    }
                case .split:
                    // Split is retained only for persisted-data compatibility.
                    // RendererPresentationState normalizes it to Rendered.
                    fallbackWithSource(reason: RendererPresentationState.unavailableFallbackMessage)
                }
            }
        }
    }

    private var controls: some View {
        Picker("Rendering", selection: selectedTab) {
            Text("Source").tag(Tab.source)
            ForEach(descriptors, id: \.reference) { descriptor in
                Text(descriptor.displayName).tag(Tab.renderer(descriptor.reference))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Source rendering")
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.vertical, 6)
    }

    private var selectedTab: Binding<Tab> {
        Binding(
            get: {
                guard state.selection == .rendered, let reference = state.pinnedRenderer else {
                    return .source
                }
                return .renderer(reference)
            },
            set: { tab in
                switch tab {
                case .source:
                    state.selectSource()
                    onPresentationSelected(.source)
                case let .renderer(reference):
                    state.selectRendered(reference)
                    onRendererSelected(reference)
                    onPresentationSelected(.rendered)
                }
            })
    }

    /// A fallback is only valid for the source that scheduled it. This pure
    /// gate also makes repeated `onAppear` callbacks idempotent.
    static func shouldApplyDeferredFallback(
        failedSourceID: SourceID,
        currentState: RendererPresentationState
    ) -> Bool {
        currentState.sourceID == failedSourceID && currentState.fallbackReason == nil
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
        .frame(minWidth: RendererHostMetrics.minimumFallbackPaneWidth, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectSourceAfterFallback(reason)
        }
    }

    private func selectSourceAfterFallback(_ reason: String) {
        // `onAppear` runs after the update pass, so this is not an AppKit
        // representable update seam. Defer one turn to avoid a synchronous
        // state mutation while SwiftUI is constructing the fallback tree.
        let failedSourceID = state.sourceID
        Task { @MainActor in
            guard Self.shouldApplyDeferredFallback(failedSourceID: failedSourceID, currentState: state) else { return }
            state.selectFallback(reason: reason)
            onFallback(reason)
        }
    }
}
#endif

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
    let rendered: (RendererDescriptor) -> Rendered
    let onRendererSelected: (RendererReference) -> Void
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
                        rendered(selectedDescriptor)
                    } else {
                        fallback(reason: "The selected renderer is unavailable.")
                    }
                case .split:
                    HSplitView {
                        source()
                        if let selectedDescriptor {
                            rendered(selectedDescriptor)
                        } else {
                            fallback(reason: "The selected renderer is unavailable.")
                        }
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Source") { state.selectSource() }
                .keyboardShortcut("1", modifiers: .command)
                .accessibilityLabel("Show source")
            Menu("Rendered") {
                ForEach(descriptors, id: \.reference) { descriptor in
                    Button(descriptor.displayName) {
                        state.selectRendered(descriptor.reference)
                        onRendererSelected(descriptor.reference)
                    }
                }
            }
            .keyboardShortcut("2", modifiers: .command)
            .accessibilityLabel("Show rendered content")
            Button("Split") {
                if let reference = state.pinnedRenderer ?? descriptors.first?.reference {
                    state.selectSplit(reference)
                    onRendererSelected(reference)
                }
            }
            .keyboardShortcut("3", modifiers: .command)
            .accessibilityLabel("Show source and rendered content")
            .disabled(descriptors.isEmpty)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func fallback(reason: String) -> some View {
        VStack(spacing: 8) {
            Text(reason).font(.callout).foregroundStyle(.secondary)
            source()
        }
        .onAppear {
            onFallback(reason)
            Task { @MainActor in
                state.selectSource()
            }
        }
    }
}
#endif

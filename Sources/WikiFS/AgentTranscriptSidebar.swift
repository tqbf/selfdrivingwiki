import SwiftUI

/// A trailing inspector for the active agent run. It reuses the operations
/// sheet's transcript renderer so inline page queries do not disappear into a
/// silent lock state.
struct AgentTranscriptSidebar: View {
    @Bindable var launcher: AgentLauncher
    @State private var showsInternals = false
    @State private var splitFraction: CGFloat = 0.3
    @State private var dragOrigin: CGFloat = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(PageEditorMetrics.dividerOpacity)
            if showsConversion {
                splitContent
            } else {
                activitySection
                    .padding(AgentTranscriptMetrics.padding)
            }
        }
        .frame(width: AgentTranscriptMetrics.width)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipped()
        .onChange(of: showsConversion) { _, newValue in
            // Reset the split when the conversion section appears or disappears.
            if newValue {
                splitFraction = 0.3
                dragOrigin = 0.3
            }
        }
    }

    /// Show the local pdf2md conversion box only while a pdf2md conversion is in
    /// flight (or has just finished) — not for Markdown ingests, queries, or
    /// lints. Driven by the extraction-phase flag `extractingFileIDs` (the
    /// agent-phase `ingestingFileIDs` no longer covers the extraction phase).
    private var showsConversion: Bool {
        !launcher.extractingFileIDs.isEmpty
            && (launcher.isExtracting || !launcher.extractionLog.isEmpty)
    }

    // MARK: - Split layout

    /// When the conversion box is visible, the two sections share the available
    /// height. A draggable grippy between them lets the user grow one while the
    /// other contracts.
    private var splitContent: some View {
        GeometryReader { proxy in
            let totalH = proxy.size.height
            let gripThickness: CGFloat = 7
            let pdfH = max(60, totalH * splitFraction)
            let activityH = max(60, totalH - pdfH - gripThickness)

            VStack(alignment: .leading, spacing: 0) {
                pdfConversionBox
                    .padding(AgentTranscriptMetrics.padding)
                    .frame(height: pdfH)

                grippy(totalHeight: totalH)
                    .frame(height: gripThickness)

                activitySection
                    .padding(AgentTranscriptMetrics.padding)
                    .frame(height: activityH)
            }
        }
    }

    /// A thin horizontal bar the user drags to resize the two sections.
    private func grippy(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 32, height: 4)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                DispatchQueue.main.async {
                    if inside {
                        NSCursor.resizeUpDown.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newFraction = dragOrigin + value.translation.height / totalHeight
                        splitFraction = min(0.75, max(0.15, newFraction))
                    }
                    .onEnded { _ in
                        dragOrigin = splitFraction
                    }
            )
    }

    // MARK: - Sections

    private var pdfConversionBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("PDF Conversion", systemImage: "doc.viewfinder")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if launcher.isExtracting {
                    ProgressView().controlSize(.small)
                    if let pid = launcher.extractionPID {
                        Text("pid \(pid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Stop Conversion", systemImage: "stop.fill") {
                        launcher.stopExtraction()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Stop PDF conversion")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(launcher.extractionLog.isEmpty ? "Converting…" : launcher.extractionLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Color.clear.frame(height: 1).id(Self.conversionBottom)
                }
                .onChange(of: launcher.extractionLog) {
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(Self.conversionBottom, anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Agent Activity", systemImage: "sparkles")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if agentBusy {
                    ProgressView().controlSize(.small)
                    Button("Stop Agent", systemImage: "stop.fill") {
                        launcher.stopAgent()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Stop the agent run")
                }
                Toggle("Show internals", isOn: $showsInternals)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AgentActivityView(launcher: launcher, showsInternals: showsInternals)
        }
    }

    private var agentBusy: Bool {
        launcher.isRunning || !launcher.ingestingFileIDs.isEmpty
    }

    private static let conversionBottom = "pdf-conversion-bottom"

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("Transcript", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
            }
        }
        .padding(.horizontal, AgentTranscriptMetrics.padding)
        .padding(.vertical, 10)
    }
}

private enum AgentTranscriptMetrics {
    static let width: CGFloat = 340
    static let padding: CGFloat = 12
}

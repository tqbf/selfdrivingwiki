import AppKit
import SwiftUI

/// A trailing inspector for the active agent run. It reuses the operations
/// sheet's transcript renderer so inline page queries do not disappear into a
/// silent lock state.
struct AgentTranscriptSidebar: View {
    @Bindable var launcher: AgentLauncher
    @State private var showsInternals = false
    @State private var splitFraction: CGFloat = 0.3
    @State private var dragOrigin: CGFloat = 0.3
    @State private var width: CGFloat = AgentTranscriptMetrics.defaultWidth
    @State private var widthDragOrigin: CGFloat = AgentTranscriptMetrics.defaultWidth

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            widthResizeHandle
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
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: PageEditorMetrics.panelCornerRadius,
                        bottomLeading: PageEditorMetrics.panelCornerRadius),
                    style: .continuous))
            .clipped()
        }
        .onChange(of: showsConversion) { _, newValue in
            // Reset the split when the conversion section appears or disappears.
            if newValue {
                splitFraction = 0.3
                dragOrigin = 0.3
            }
        }
    }

    /// A thin draggable strip on the sidebar's leading edge — dragging it left
    /// widens the sidebar, dragging right narrows it, clamped to a sane range.
    private var widthResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                DispatchQueue.main.async {
                    if inside {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let proposed = widthDragOrigin - value.translation.width
                        width = min(AgentTranscriptMetrics.maxWidth, max(AgentTranscriptMetrics.minWidth, proposed))
                    }
                    .onEnded { _ in widthDragOrigin = width }
            )
    }

    /// Show the local pdf2md conversion box only while a pdf2md conversion is in
    /// flight (or has just finished) — not for Markdown ingests, queries, or
    /// lints. Driven by the extraction-phase flag `extractingSourceIDs` (the
    /// agent-phase `ingestingSourceIDs` no longer covers the extraction phase).
    private var showsConversion: Bool {
        !launcher.extractingSourceIDs.isEmpty
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
                if launcher.isRunning {
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
            AgentRunBanner(isVisible: isAgentActive, kind: launcher.runningKind)
            AgentActivityView(launcher: launcher, showsInternals: showsInternals)
        }
    }

    private static let conversionBottom = "pdf-conversion-bottom"

    /// True only while the agent is actively producing output — drives the status
    /// banner at the top of the sidebar. Turn-aware (uses `isGenerating`) so an
    /// open-but-idle interactive session does not leave the banner up. The Stop
    /// button below keys off `isRunning` instead, so an idle session can still be
    /// ended.
    private var isAgentActive: Bool {
        launcher.isGenerating
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("Activity", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
            }
        }
        .padding(.horizontal, AgentTranscriptMetrics.padding)
        .padding(.vertical, 10)
    }
}

enum AgentTranscriptMetrics {
    static let defaultWidth: CGFloat = 340
    static let minWidth: CGFloat = 260
    static let maxWidth: CGFloat = 720
    static let padding: CGFloat = 12
}

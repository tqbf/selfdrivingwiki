import AppKit
import SwiftUI
import WikiFSCore

/// A trailing inspector for the active agent run. It reuses the operations
/// sheet's transcript renderer so inline page queries do not disappear into a
/// silent lock state.
struct AgentTranscriptSidebar: View {
    @Bindable var launcher: AgentLauncher
    /// Forwards wiki-link clicks in the transcript to the detail column. Built
    /// where the store lives (the owning `ContentView` / `LintView`) and
    /// forwarded unchanged to the activity view.
    var onWikiLink: ((URL, Bool) -> Void)? = nil
    @State private var showsInternals = false
    @State private var width: CGFloat = AgentTranscriptMetrics.defaultWidth
    @State private var widthDragOrigin: CGFloat = AgentTranscriptMetrics.defaultWidth

    /// Which section is currently shown. Like Xcode's navigator, the icon bar at
    /// the top of the sidebar is a mutually-exclusive selector — exactly one
    /// section's "window" is visible at a time. Pure UI state — not persisted.
    @State private var selectedSection: SidebarSection = .activity

    enum SidebarSection: String, CaseIterable, Identifiable {
        case activity, extraction

        var id: String { rawValue }

        var title: String {
            switch self {
            case .activity: "Activity"
            case .extraction: "Extraction"
            }
        }

        var systemImage: String {
            switch self {
            case .activity: "sparkles"
            case .extraction: "doc.viewfinder"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            widthResizeHandle
            VStack(alignment: .leading, spacing: 0) {
                sectionSelectorBar
                    .padding(.top, 8)
                Divider().opacity(PageEditorMetrics.dividerOpacity)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: launcher.isExtracting) { _, newValue in
            if newValue {
                selectedSection = .extraction
            }
        }
        .onChange(of: launcher.isRunning) { _, newValue in
            if newValue {
                selectedSection = .activity
            }
        }
        .onAppear {
            if launcher.isExtracting {
                selectedSection = .extraction
            } else if launcher.isRunning {
                selectedSection = .activity
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .activity:
            activitySection
                .padding(AgentTranscriptMetrics.padding)
        case .extraction:
            pdfConversionBox
                .padding(AgentTranscriptMetrics.padding)
        }
    }

    /// A row of evenly-spaced icons — one per section — that selects which
    /// section's "window" is shown, exactly like Xcode's navigator selector.
    private var sectionSelectorBar: some View {
        HStack(spacing: 0) {
            ForEach(SidebarSection.allCases) { section in
                sectionSelectorButton(section)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func sectionSelectorButton(_ section: SidebarSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            Image(systemName: section.systemImage)
                .font(.body)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.title)
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
            AgentActivityView(launcher: launcher, showsInternals: showsInternals, onWikiLink: onWikiLink)
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
}

enum AgentTranscriptMetrics {
    static let defaultWidth: CGFloat = 340
    static let minWidth: CGFloat = 260
    static let maxWidth: CGFloat = 720
    static let padding: CGFloat = 12
}

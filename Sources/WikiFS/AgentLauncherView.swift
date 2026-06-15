import SwiftUI

/// The "Run Agent" sheet (INITIAL §8 / M6). An editable monospaced command
/// field, Run/Stop controls, and a scrolling selectable output console that
/// auto-scrolls and reports the exit status.
///
/// Type scale matches `VerificationPopover` (headline title, secondary
/// subheadline, monospaced code) so the two utility surfaces feel like one app.
struct AgentLauncherView: View {
    @Bindable var launcher: AgentLauncher
    let fileProvider: FileProviderSpike
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            commandSection
            controls
            outputConsole
            footer
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Run Agent")
                .font(.headline)
            Text("Runs a command with WIKI_ROOT set to the live read-only mount. Treat the wiki as input.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.subheadline)
                .fontWeight(.medium)
            TextEditor(text: $launcher.command)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 84)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .disabled(launcher.isRunning)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if launcher.isRunning {
                Button("Stop", systemImage: "stop.fill") { launcher.stop() }
                    .tint(.red)
                ProgressView().controlSize(.small)
            } else {
                Button("Run", systemImage: "play.fill") { run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(resolvedRoot == nil)
            }
            Spacer()
            wikiRootLabel
        }
    }

    @ViewBuilder
    private var wikiRootLabel: some View {
        if let root = resolvedRoot {
            Label(root, systemImage: "folder")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .lineLimit(1)
                .help("WIKI_ROOT — the live File Provider mount")
        } else {
            Label("Resolving mount…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputConsole: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(launcher.output.isEmpty ? "No output yet." : launcher.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(launcher.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id(Self.bottomAnchor)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: launcher.output) {
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            exitStatusLabel
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var exitStatusLabel: some View {
        if let status = launcher.exitStatus {
            Label(
                status == 0 ? "Exited 0" : "Exited \(status)",
                systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(status == 0 ? .green : .red)
        } else if launcher.isRunning {
            Text("Running…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private static let bottomAnchor = "agent-output-bottom"

    /// The live mount path resolved by the File Provider manager (never
    /// hardcoded). Nil until registration resolves it.
    private var resolvedRoot: String? { fileProvider.path }

    private func run() {
        guard let root = resolvedRoot else { return }
        // Signal the daemon so the generated indexes pick up any just-saved edit
        // before the agent reads them. Refresh is eventually-consistent (~5 s);
        // the agent's own find/cat also force materialization. NOT a fixed sleep.
        Task {
            await fileProvider.signalChange()
            launcher.run(wikiRoot: root)
        }
    }
}

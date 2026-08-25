import Foundation
import Observation
import SwiftUI
import WikiFSCore

@MainActor
@Observable
final class ToolchainSetupModel {
    enum Tool: String, CaseIterable, Identifiable, Sendable {
        case mise
        case bun
        case uv

        var id: Self { self }

        var title: String {
            switch self {
            case .mise: "mise"
            case .bun: "Bun 1.4"
            case .uv: "uv 0.9"
            }
        }

        var symbolName: String {
            switch self {
            case .mise: "shippingbox"
            case .bun: "shippingbox.fill"
            case .uv: "terminal"
            }
        }
    }

    enum Status: Equatable, Sendable {
        case checking
        case ready(String)
        case missing
        case failed(String)
    }

    private(set) var statuses: [Tool: Status] = Dictionary(
        uniqueKeysWithValues: Tool.allCases.map { ($0, .checking) })
    private(set) var isInstalling = false
    private(set) var installOutput: String?
    private(set) var lastError: String?

    var isReady: Bool {
        Tool.allCases.allSatisfy {
            if case .ready = statuses[$0] { return true }
            return false
        }
    }

    var hasMissingTools: Bool {
        statuses.values.contains {
            if case .missing = $0 { return true }
            return false
        }
    }

    var missingToolNames: String {
        Tool.allCases.compactMap { tool in
            guard case .missing = statuses[tool] else { return nil }
            return tool.title
        }.joined(separator: ", ")
    }

    func refresh() async {
        statuses = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, .checking) })
        lastError = nil
        installOutput = nil

        let mise = await locateExecutable(named: "mise")
        guard let mise else {
            statuses[.mise] = .missing
            statuses[.bun] = .missing
            statuses[.uv] = .missing
            return
        }
        statuses[.mise] = .ready(mise.path)

        async let bun = locateManagedTool("bun", using: mise)
        async let uv = locateManagedTool("uv", using: mise)
        statuses[.bun] = await status(for: bun)
        statuses[.uv] = await status(for: uv)
    }

    func installTools() async {
        guard !isInstalling, let mise = await locateExecutable(named: "mise") else { return }
        isInstalling = true
        installOutput = nil
        defer { isInstalling = false }

        let request = AsyncProcessRequest(
            executableURL: mise,
            arguments: ["install"],
            environment: processEnvironment,
            outputMode: .combined)
        do {
            let result = try await AsyncProcessRunner.run(request)
            installOutput = String(data: result.combinedData, encoding: .utf8)
            if result.terminationStatus == 0 {
                await refresh()
            } else {
                lastError = installOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "mise install exited with status \(result.terminationStatus)."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func status(for path: URL?) -> Status {
        guard let path else { return .missing }
        return .ready(path.path)
    }

    private func locateManagedTool(_ name: String, using mise: URL) async -> URL? {
        let request = AsyncProcessRequest(
            executableURL: mise,
            arguments: ["which", name],
            environment: processEnvironment,
            outputMode: .combined)
        do {
            let result = try await AsyncProcessRunner.run(request)
            guard result.terminationStatus == 0,
                  let output = String(data: result.combinedData, encoding: .utf8)
            else { return nil }
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    private func locateExecutable(named name: String) async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" +
            (ProcessInfo.processInfo.environment["PATH"] ?? "")
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private var processEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [
            "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        environment["PATH"] = additions.joined(separator: ":") + ":" +
            (environment["PATH"] ?? "")
        return environment
    }
}

struct ToolchainSetupSheet: View {
    @Bindable var model: ToolchainSetupModel
    let dismiss: () -> Void
    let openInstallationGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            Label("Set Up Development Tools", systemImage: "wrench.and.screwdriver")
                .font(.title2.weight(.semibold))

            Text("Self Driving Wiki uses mise to manage Bun and uv. These tools are not included in the app bundle.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(ToolchainSetupModel.Tool.allCases) { tool in
                    ToolchainStatusRow(tool: tool, status: model.statuses[tool] ?? .checking)
                    if tool != ToolchainSetupModel.Tool.allCases.last {
                        Divider()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).stroke(.quaternary)
            }

            if let error = model.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let output = model.installOutput, !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Metrics.outputHeight)
            }

            Text("Install mise, then run `mise install` from the repository directory. The app can run that final step after mise is installed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open mise Guide") { openInstallationGuide() }
                Button("Copy Commands") { copyCommands() }
                Spacer()
                Button("Check Again") {
                    Task { await model.refresh() }
                }
                if model.statuses[.mise].map(isReadyStatus) == true && !model.isReady {
                    Button(model.isInstalling ? "Installing…" : "Install Tools") {
                        Task { await model.installTools() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstalling)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .task { await model.refresh() }
    }

    private func isReadyStatus(_ status: ToolchainSetupModel.Status) -> Bool {
        if case .ready = status { return true }
        return false
    }

    private func copyCommands() {
        let commands = """
        brew install mise
        cd /path/to/selfdrivingwiki
        mise install
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    private enum Metrics {
        static let width: CGFloat = 560
        static let padding: CGFloat = 24
        static let sectionSpacing: CGFloat = 16
        static let outputHeight: CGFloat = 110
    }
}

private struct ToolchainStatusRow: View {
    let tool: ToolchainSetupModel.Tool
    let status: ToolchainSetupModel.Status

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.symbolName)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(tool.title)
            Spacer()
            statusView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(let path):
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(path)
        case .missing:
            Label("Missing", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

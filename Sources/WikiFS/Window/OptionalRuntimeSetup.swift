import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class OptionalRuntimeSetupModel {
    enum Runtime: String, CaseIterable, Identifiable {
        case bun
        case uv

        var id: Self { self }

        var title: String {
            switch self {
            case .bun: "Bun"
            case .uv: "uv"
            }
        }

        var purpose: String {
            switch self {
            case .bun: "HTML article extraction and ACP providers"
            case .uv: "Local PDF and transcript extraction"
            }
        }

        var installURL: URL {
            switch self {
            case .bun: URL(string: "https://bun.com/docs/installation")!
            case .uv: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!
            }
        }
    }

    private(set) var paths: [Runtime: String?] = [:]

    var missingRuntimes: [Runtime] {
        Runtime.allCases.filter { paths[$0] == nil }
    }

    var isComplete: Bool { missingRuntimes.isEmpty }

    func refresh() {
        paths = Dictionary(uniqueKeysWithValues: Runtime.allCases.map { runtime in
            (runtime, executablePath(named: runtime.rawValue))
        })
    }

    private func executablePath(named name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}

struct OptionalRuntimeSetupSheet: View {
    @Bindable var model: OptionalRuntimeSetupModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            Label("Optional Development Tools", systemImage: "wand.and.stars")
                .font(.title2.weight(.semibold))

            Text("Self Driving Wiki works without these tools. Install them if you want local PDF, transcript, HTML extraction, or Bun-based ACP integrations.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(OptionalRuntimeSetupModel.Runtime.allCases) { runtime in
                    RuntimeStatusRow(runtime: runtime, path: model.paths[runtime] ?? nil)
                    if runtime != OptionalRuntimeSetupModel.Runtime.allCases.last {
                        Divider()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary) }

            if !model.isComplete {
                Text("You can install these tools with any method — Homebrew, an official installer, or a version manager. They work when your login shell can run them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Bun Guide") { open(.bun) }
                Button("Open uv Guide") { open(.uv) }
                Button("Copy Commands") { copyCommands() }
                Spacer()
                Button("Check Again") { model.refresh() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .task { model.refresh() }
    }

    private func open(_ runtime: OptionalRuntimeSetupModel.Runtime) {
        NSWorkspace.shared.open(runtime.installURL)
    }

    private func copyCommands() {
        let commands = """
        brew install oven-sh/bun/bun
        brew install uv
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    private enum Metrics {
        static let width: CGFloat = 560
        static let padding: CGFloat = 24
        static let sectionSpacing: CGFloat = 16
    }
}

private struct RuntimeStatusRow: View {
    let runtime: OptionalRuntimeSetupModel.Runtime
    let path: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: runtime == .bun ? "shippingbox.fill" : "terminal")
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.title)
                Text(runtime.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let path {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(path)
            } else {
                Label("Not installed", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

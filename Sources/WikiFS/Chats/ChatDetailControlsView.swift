// pattern: Imperative Shell

import AppKit
import SwiftUI

struct ChatDetailControlsView: View {
    let showsDebugControls: Bool
    let isAnswering: Bool
    @Binding var showsInternals: Bool
    @Binding var hideToolCalls: Bool
    let exitStatus: Int32?
    let debugFolderURL: URL?
    let copyDiagnostics: () -> Void
    let writeDiagnosticsJSONL: (URL) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsDebugControls {
                if isAnswering {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Toggle("Show Full Activity", isOn: $showsInternals)
                    Toggle("Hide tool calls", isOn: $hideToolCalls)
                    Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                        copyDiagnostics()
                    }
                    .help("Copy a redacted app and daemon diagnostic snapshot")
                    if let exitStatus {
                        Label(
                            exitStatus == 0 ? "Ended" : "Exited \(exitStatus)",
                            systemImage: exitStatus == 0 ? "checkmark.circle" : "xmark.circle"
                        )
                    }
                    if let debugFolderURL {
                        Button("Write Redacted Diagnostics JSONL", systemImage: "doc.text") {
                            writeDiagnosticsJSONL(debugFolderURL.appendingPathComponent("chat-diagnostics.jsonl"))
                        }
                        .help("Append redacted trace records to the debug folder")
                        Button("Reveal Debug Folder", systemImage: "folder.badge.gearshape") {
                            NSWorkspace.shared.activateFileViewerSelecting([debugFolderURL])
                        }
                        .help("Open the complete debug trace folder (ACP messages, permissions, usage)")
                    }
                } label: {
                    Label("Activity", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .help("Show activity controls while this chat is running")
            }
        }
    }
}

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

    var body: some View {
        HStack(spacing: 8) {
            if showsDebugControls {
                if isAnswering {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Toggle("Show internals", isOn: $showsInternals)
                    Toggle("Hide tool calls", isOn: $hideToolCalls)
                    if let exitStatus {
                        Label(
                            exitStatus == 0 ? "Ended" : "Exited \(exitStatus)",
                            systemImage: exitStatus == 0 ? "checkmark.circle" : "xmark.circle"
                        )
                    }
                    if let debugFolderURL {
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
                .help("Show activity and transcript internals")
            }
        }
    }
}

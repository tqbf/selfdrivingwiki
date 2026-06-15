import AppKit
import SwiftUI

/// The "Copy Unix Path" popover (INITIAL §7 / M4). Resolves the File Provider
/// user-visible root URL AT CLICK TIME (never hardcoded), copies it to the
/// pasteboard, and shows it plus a copyable verification command the user can
/// paste into Terminal to confirm the projection.
///
/// The path is bound to the observable `FileProviderSpike.path`, so if
/// resolution is still in flight when the popover opens it fills in live.
struct VerificationPopover: View {
    let fileProvider: FileProviderSpike

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            pathSection
            Divider()
            verificationSection
            revealButton
        }
        .padding(20)
        .frame(width: 460)
        .task { await copyPathToPasteboard() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Filesystem Path")
                .font(.headline)
            Text("This wiki is mounted read-only via File Provider. Inspect it from Terminal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pathSection: some View {
        if let path = fileProvider.path {
            VStack(alignment: .leading, spacing: 6) {
                Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Resolving path…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Verify in Terminal")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    copyToPasteboard(verificationCommand)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Copy the verification command")
                .disabled(fileProvider.path == nil)
            }
            Text(verificationCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var revealButton: some View {
        if let path = fileProvider.path {
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    /// The verification command shown in the popover. Falls back to a placeholder
    /// while the path is still resolving.
    private var verificationCommand: String {
        let target = fileProvider.path ?? "<path>"
        return #"cd "\#(target)" && find . && cat pages/by-title/Home--*.md"#
    }

    /// Resolve (if needed) and copy the root path to the pasteboard.
    private func copyPathToPasteboard() async {
        if fileProvider.path == nil {
            await fileProvider.resolvePath()
        }
        if let path = fileProvider.path {
            copyToPasteboard(path)
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

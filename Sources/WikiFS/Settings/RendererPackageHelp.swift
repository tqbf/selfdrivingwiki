#if os(macOS)
import SwiftUI

enum RendererPackageHelpCopy {
    static let triggerTitle = "What is a renderer package?"
    static let tooltip = "Learn about local renderer packages"
    static let heading = "Renderer packages"
    static let folderExample = """
        ExampleRenderer/
        ├── manifest.json
        └── index.html
        """
}

struct RendererPackageHelpControl: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button(RendererPackageHelpCopy.triggerTitle, systemImage: "questionmark.circle") {
            presentHelp()
        }
        .accessibilityIdentifier("renderer-package-help-button")
        .accessibilityLabel(RendererPackageHelpCopy.triggerTitle)
        .help(RendererPackageHelpCopy.tooltip)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            RendererPackageHelpContent()
        }
    }

    func presentHelp() {
        isPresented = true
    }
}

struct RendererPackageHelpContent: View {
    private enum Metrics {
        static let width: CGFloat = 420
        static let maximumHeight: CGFloat = 560
        static let spacing: CGFloat = 12
        static let compactSpacing: CGFloat = 6
        static let padding: CGFloat = 20
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text(RendererPackageHelpCopy.heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Text("A renderer package is one local folder. It contains manifest.json and the static HTML, JavaScript, CSS, image, or font files that the manifest declares.")
                    .font(.body)

                Text(RendererPackageHelpCopy.folderExample)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Example renderer folder with manifest.json and index.html")

                helpSection(
                    "What the manifest declares",
                    text: "manifest.json declares the package identity, matching rules, capabilities, limits, assets, and lowercase SHA-256 digests.")

                helpSection(
                    "What import does",
                    text: "The app validates the selected folder and copies it for use on this Mac. It does not use the selected source folder after import. Every compatible installed renderer is available to every wiki on this Mac.")

                helpSection(
                    "Supported sources",
                    text: "Import accepts one local folder. ZIP files, other archives, remote catalogs, and network installation are not supported.")

                helpSection(
                    "Fallback stays available",
                    text: "If a package is missing, incompatible, suppressed by safe mode, or cannot render, Source and native renderer fallback stay available.")
            }
            .padding(Metrics.padding)
        }
        .frame(width: Metrics.width)
        .frame(maxHeight: Metrics.maximumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RendererPackageHelpCopy.heading)
    }

    private func helpSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.compactSpacing) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

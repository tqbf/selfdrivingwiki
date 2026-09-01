#if os(macOS)
import SwiftUI

enum ExtractorPackageHelpCopy {
    static let triggerTitle = "What is an extractor package?"
    static let tooltip = "Learn about local extractor packages"
    static let heading = "Extractor packages"
    static let folderExample = """
        ExampleExtractor/
        ├── manifest.json
        └── bin/
            └── example-extractor.js
        """
}

struct ExtractorPackageHelpControl: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button(ExtractorPackageHelpCopy.triggerTitle, systemImage: "questionmark.circle") {
            presentHelp()
        }
        .accessibilityIdentifier("extractor-package-help-button")
        .accessibilityLabel(ExtractorPackageHelpCopy.triggerTitle)
        .help(ExtractorPackageHelpCopy.tooltip)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            ExtractorPackageHelpContent()
        }
    }

    func presentHelp() {
        isPresented = true
    }
}

struct ExtractorPackageHelpContent: View {
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
                Text(ExtractorPackageHelpCopy.heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Text("An extractor package turns one file into Markdown. It is one local folder that contains manifest.json, the entry point, and the other files that the manifest declares.")
                    .font(.body)

                Text(ExtractorPackageHelpCopy.folderExample)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Example extractor folder with manifest.json and an entry point under bin")

                // The one thing that separates an extractor package from a
                // renderer package: it runs code. State it before anything
                // else the reader might act on.
                Label(ExtractionSettingsView.trustWarningMessage, systemImage: "exclamationmark.triangle")
                    .font(.body)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Executable code warning. \(ExtractionSettingsView.trustWarningMessage)")

                helpSection(
                    "What the manifest declares",
                    text: "manifest.json declares the package identity, the registrations that say which formats the package extracts, the launch mode, the capabilities, the operation limits, and lowercase SHA-256 digests for every declared file.")

                helpSection(
                    "How a package runs",
                    text: "A package runs as a one-shot process. One request goes in, and one terminal frame comes back as JSON Lines. Each operation takes one input file and returns one Markdown result. Declared capabilities are a declaration, not a security sandbox.")

                helpSection(
                    "What import does",
                    text: "The app validates the selected folder and copies it into the extractor store on this Mac. It does not use the selected source folder after import. Every installed revision is pinned to its exact digest.")

                helpSection(
                    "Supported sources",
                    text: "Import accepts one local folder. ZIP files, other archives, remote catalogs, and network installation are not supported.")

                helpSection(
                    "Reviewed and installed packages",
                    text: "Reviewed packages ship with the app. Installed packages are local additions. Both appear in this table, and the Defaults tab chooses which one opens each format.")

                helpSection(
                    "Credentials stay explicit",
                    text: "A package can declare a credential requirement. You authorize each one, and the app names the stored credential before you approve. A later revision of the same package keeps the grant only while that requirement's label, purpose, optionality, and registration stay unchanged.")

                helpSection(
                    "When a package cannot run",
                    text: "A revision that fails to activate keeps its row and shows the reason. A format whose selected package is missing or not ready stays blocked until you choose another extractor in the Defaults tab.")
            }
            .padding(Metrics.padding)
        }
        .frame(width: Metrics.width)
        .frame(maxHeight: Metrics.maximumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ExtractorPackageHelpCopy.heading)
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

import SwiftUI
import WikiFSCore

/// Renders a provider's `ProviderConfigSchema` as a **native SwiftUI `Form`** —
/// the resolution of issue #483. The manifest's schema (decoded from JSON) is
/// the portable, drop-in contract; this view is the ~one-file renderer that maps
/// each `SchemaField` to a native control. No WKWebView, no JS bridge — you get
/// native focus rings, SecureField behavior, and VoiceOver for free, and a new
/// provider needs zero Swift here, just a schema.
///
/// Values are a flat `[String: String]` binding (spike simplicity): every field
/// round-trips through its string form, and non-string types (`boolean`,
/// `number`, `enum`) coerce at the control boundary. The container owns Save /
/// Test and decides which keys are secrets (via the schema's `secret` flag).
struct SchemaForm: View {
    let schema: ProviderConfigSchema
    @Binding var values: [String: String]

    var body: some View {
        Form {
            ForEach(schema.fields) { field in
                fieldRow(field)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func fieldRow(_ field: SchemaField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            control(for: field)
            if let help = field.help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func control(for field: SchemaField) -> some View {
        if field.format == .password {
            SecureField(field.title, text: stringBinding(field))
                .textFieldStyle(.roundedBorder)
        } else if let options = field.enumValues, !options.isEmpty {
            Picker(field.title, selection: stringBinding(field)) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        } else if field.type == .boolean {
            Toggle(field.title, isOn: boolBinding(field))
        } else if field.format == .path {
            LabeledContent(field.title) {
                HStack {
                    TextField(field.placeholder ?? "", text: stringBinding(field))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseDirectory(field) }
                }
            }
        } else {
            LabeledContent(field.title) {
                TextField(field.placeholder ?? "", text: stringBinding(field))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Bindings

    /// A string binding into `values` for `field`, defaulting to "".
    private func stringBinding(_ field: SchemaField) -> Binding<String> {
        Binding(
            get: { values[field.name] ?? "" },
            set: { values[field.name] = $0 }
        )
    }

    /// A bool binding that stores `"true"` / `"false"` in the string map.
    private func boolBinding(_ field: SchemaField) -> Binding<Bool> {
        Binding(
            get: { (values[field.name] ?? "false") == "true" },
            set: { values[field.name] = $0 ? "true" : "false" }
        )
    }

    private func chooseDirectory(_ field: SchemaField) {
        if let url = WikiFilePanels.chooseDirectory(
            title: "Choose \(field.title)", prompt: "Choose") {
            values[field.name] = url.path
        }
    }
}

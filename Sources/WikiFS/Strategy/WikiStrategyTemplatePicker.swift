import SwiftUI
import WikiFSCore

/// The starter-template picker: one native menu-style `Picker` listing the
/// six templates (picker order = `WikiStrategyTemplates.all` order).
///
/// Selecting a template does not save and does not touch pages — the picker
/// only hands the template to `onSelect` (the editor copies it into the local
/// draft, after a confirmation when the draft already holds text). Templates
/// are starting text, not live dependencies.
struct WikiStrategyTemplatePicker: View {
    let onSelect: (WikiStrategyTemplate) -> Void

    /// `nil` is the "Choose a template" prompt. Reset to `nil` after every
    /// selection so choosing the same template twice fires `onChange` again.
    @State private var selection: WikiStrategyTemplateID?

    var body: some View {
        Picker("Start from a Template", selection: $selection) {
            Text("Choose a template…").tag(WikiStrategyTemplateID?.none)
            ForEach(WikiStrategyTemplates.all) { template in
                Text(template.name).tag(WikiStrategyTemplateID?.some(template.id))
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selection) { _, chosen in
            // Return to the prompt first so the same template can be chosen
            // again later. This write happens in the change handler, not
            // during a view update.
            selection = nil
            guard let id = chosen else { return }
            onSelect(WikiStrategyTemplates.template(for: id))
        }
        .accessibilityLabel("Strategy template")
        .accessibilityHint("Copies the template name and instructions into the draft")
        .help("Copy a starter template's name and instructions into the draft")
    }
}

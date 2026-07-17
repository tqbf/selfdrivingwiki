import SwiftUI

/// A compact find bar overlaid at the top of the content area — mirrors
/// the native macOS find bar in look and feel. Driven by a `FindModel`.
///
/// Layout: [Search Field] [count label] [‹][›] [Aa] [Done]
/// Keyboard: Enter = next, Shift+Enter = previous, Esc = dismiss
struct FindBarView: View {
    @Bindable var model: FindModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Leading edge — same inset as the content area.
            Spacer().frame(width: 4)

            // Search field with magnifying glass + clear button.
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("Find", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($fieldFocused)
                    .onSubmit { model.nextMatch() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
            )
            .frame(width: 200)

            // Match count.
            if !model.countLabel.isEmpty {
                Text(model.countLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            // Next / Previous.
            HStack(spacing: 2) {
                Button { model.previousMatch() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(model.matches.isEmpty)
                .help("Previous match (⇧↩)")

                Button { model.nextMatch() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(model.matches.isEmpty)
                .help("Next match (↩)")
            }

            // Case toggle.
            Button {
                model.caseSensitive.toggle()
            } label: {
                Text("Aa")
                    .font(.callout.weight(model.caseSensitive ? .bold : .regular))
                    .foregroundStyle(model.caseSensitive ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Match case")

            // Done.
            Button("Done") { model.dismiss() }
                .buttonStyle(.borderless)
                .font(.callout)
                .keyboardShortcut(.escape, modifiers: [])

            Spacer().frame(width: 4)
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: model.isShowing) { _, showing in
            if showing { fieldFocused = true }
        }
        .onChange(of: model.query) { model.search() }
        .onChange(of: model.caseSensitive) { model.search() }
    }
}

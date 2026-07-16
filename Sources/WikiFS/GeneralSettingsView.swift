import SwiftUI

/// Settings → General tab: app-level toggles that don't fit a domain tab.
///
/// Currently hosts the "Confirm before quitting" toggle (key
/// `confirmBeforeQuitting`, default on). When enabled, a dialog asks the user
/// to confirm before the app terminates — catching ⌘Q / Apple menu Quit / Dock
/// Quit / system shutdown.
struct GeneralSettingsView: View {
    @AppStorage(QuitConfirmationDelegate.confirmQuitKey)
    private var confirmBeforeQuitting = true

    var body: some View {
        Form {
            Section {
                Toggle("Ask before quitting", isOn: $confirmBeforeQuitting)
                    .help(
                        "When enabled, Self Driving Wiki asks for confirmation "
                        + "before quitting — ⌘Q, or closing the last window with ⌘W."
                    )
            } header: {
                Text("Quitting")
            } footer: {
                Text(
                    "You can always quit immediately by choosing "
                    + "\"Quit\" in the confirmation dialog, or by turning this off."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 460, height: 460)
}

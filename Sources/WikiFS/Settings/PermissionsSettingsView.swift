import SwiftUI
import WikiFSEngine

/// Settings → **Permissions** tab.
///
/// Previously lived as `permissionSection` inside `AgentsSettingsView`; split
/// into its own tab so the Agents tab (provider list) no longer pushes the
/// permission pickers below the fold when there are more than ~3 providers
/// (the Form clipped without scrolling, hiding the permissions entirely).
///
/// The `@AppStorage` keys (`AgentLauncher.PermissionModeKey.chat/ingest/lint`)
/// are independent of the view, so the same bindings work here as they did
/// inline in `AgentsSettingsView`. See `plans/acp-permissions.md` §5.1 for
/// the rationale behind three independent per-operation pickers (pre-split, a
/// single shared key fed chat + ingest + lint — a user who chose `alwaysAsk`
/// for chat got the same gating on unattended ingest/lint, guaranteeing a
/// stall on the first prompt needing a permission).
///
/// Extraction is intentionally NOT a kind here — it keeps its `.bypass`
/// default on `ACPExtractionClient`.
///
/// Also hosts the "Ask before quitting" toggle in the "App Behavior" section.
/// That toggle previously lived on a standalone General tab; the General tab
/// was removed for not justifying a whole tab, and the About tab was removed
/// shortly after for the same reason (only version info, which is already
/// surfaced in the app's standard About window). The toggle landed here
/// because permissions is the closest semantically to "app behavior" — it's
/// the only Settings tab whose controls affect the app's runtime behavior
/// rather than per-wiki content.
struct PermissionsSettingsView: View {
    @AppStorage(AgentLauncher.PermissionModeKey.chat)   private var chatModeRaw   = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.ingest) private var ingestModeRaw = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.lint)   private var lintModeRaw   = PermissionPolicy.bypass.rawValue
    @AppStorage(AppDelegate.confirmQuitKey) private var confirmBeforeQuitting = true

    var body: some View {
        Form {
            Section {
                Picker("Chat Permission Mode", selection: $chatModeRaw) {
                    ForEach(PermissionPolicy.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                Picker("Ingest Permission Mode", selection: $ingestModeRaw) {
                    ForEach(PermissionPolicy.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                Picker("Lint Permission Mode", selection: $lintModeRaw) {
                    ForEach(PermissionPolicy.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("These control how the app responds to the agent's permission requests for each operation. Ingest and Lint run unattended — Bypass is recommended (the sandbox already confines writes; an unattended pipeline can't use Always Ask productively, and a stuck permission would auto-reject after 60s).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App Behavior") {
                Toggle("Ask before quitting", isOn: $confirmBeforeQuitting)
                    .help(
                        "When enabled, Self Driving Wiki asks for confirmation "
                        + "before quitting — ⌘Q, or closing the last window with ⌘W."
                    )
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    PermissionsSettingsView()
        .frame(width: 460, height: 460)
}

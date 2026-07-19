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
struct PermissionsSettingsView: View {
    @AppStorage(AgentLauncher.PermissionModeKey.chat)   private var chatModeRaw   = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.ingest) private var ingestModeRaw = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.lint)   private var lintModeRaw   = PermissionPolicy.bypass.rawValue

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
        }
        .formStyle(.grouped)
    }
}

#Preview {
    PermissionsSettingsView()
        .frame(width: 460, height: 460)
}

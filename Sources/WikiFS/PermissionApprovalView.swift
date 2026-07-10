import SwiftUI
import WikiFSCore
import ACPModel

/// The inline Approve/Reject affordance for a pending write-permission request
/// (always-ask mode, slice 2 of `plans/acp-backend-and-permissions.md`). Renders
/// the agent's offered options as buttons: an `allow_*` option → the primary
/// Approve action; a `reject_*` (or other) option → Reject. Tapping a button
/// resolves the request via the launcher, unblocking the agent.
///
/// Native macOS idiom (per the `macos-design` + `swiftui-pro` skills): a
/// compact card with `.regularMaterial` vibrancy, a leading shield glyph, the
/// request's title, and a trailing button pair (accented Approve, plain
/// Reject). Accessible: each button is labeled and has a help tooltip; the
/// card announces itself to VoiceOver.
struct PermissionApprovalView: View {
    let permission: PendingPermission
    let onResolve: (String) -> Void

    /// Split the offered options into the allow (Approve) and deny (Reject)
    /// buckets. An option whose `kind` starts with `allow` is Approve; the
    /// first remaining option is Reject. ACP requests typically offer exactly
    /// these two, but this degrades gracefully if more or fewer are offered.
    private var allowOption: PermissionOption? {
        permission.options.first(where: { $0.kind.hasPrefix("allow") })
    }
    private var rejectOption: PermissionOption? {
        permission.options.first(where: { !$0.kind.hasPrefix("allow") })
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("The agent is waiting for your approval to proceed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let reject = rejectOption {
                    Button("Reject") { onResolve(reject.optionId) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Deny this request")
                }
                if let allow = allowOption {
                    Button("Approve") { onResolve(allow.optionId) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Allow this request")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request awaiting approval")
    }

    /// The request's title: the tool-call's title if offered (e.g. "Edit file"),
    /// otherwise a generic "Approve write?" prompt.
    private var titleText: String {
        permission.title ?? "Approve this change?"
    }
}

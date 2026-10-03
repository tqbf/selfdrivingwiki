import SwiftUI

/// The native inline confirmation shared by the strategy surfaces: the
/// editor's pending actions (template replace, reset, conflict reload) and
/// the window-level wiki-switch guard. One message plus two ordinary
/// buttons — Confirm runs `onConfirm`, Cancel runs `onCancel`.
///
/// Deliberately an INLINE row of real controls rather than a system alert:
/// it renders inside the hosted view tree, so keyboard, VoiceOver, and
/// hosted-control tests all see ordinary buttons wherever the app presents
/// it. `confirmTitle` and `cancelTitle` are distinct per use site so
/// accessibility-label-based control finding is unambiguous.
struct WikiStrategyInlineConfirmation: View {
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                    Button(cancelTitle, role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(WikiStrategyEditorMetrics.calloutPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WikiStrategyEditorMetrics.cornerRadius)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WikiStrategyEditorMetrics.cornerRadius)
                .strokeBorder(Color.secondary.opacity(0.35))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Strategy confirmation")
        .accessibilityValue(confirmTitle)
    }
}

import SwiftUI

/// Subtle rounded-rect row background shown on hover, as a click affordance.
/// Uses `Color.primary` so the tint adapts to light/dark automatically
/// (darkens in light mode, lightens in dark mode) — no manual appearance branch.
struct HoverRowBackground: ViewModifier {
    var cornerRadius: CGFloat = 6
    var opacity: Double = 0.07
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? opacity : 0))
            )
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

extension View {
    /// Hover-driven subtle row highlight. Apply to the full row (after its
    /// `.contentShape`/frame) so the bubble spans the whole hit area.
    func hoverRowBackground(cornerRadius: CGFloat = 6, opacity: Double = 0.07) -> some View {
        modifier(HoverRowBackground(cornerRadius: cornerRadius, opacity: opacity))
    }
}

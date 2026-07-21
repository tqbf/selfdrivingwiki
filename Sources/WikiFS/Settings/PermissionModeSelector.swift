import SwiftUI
import WikiFSEngine

/// Permission-mode selector for the chat composer, mirroring `ProviderSelector`:
/// a compact chip trigger (glyph + label + chevron) that opens a native popover
/// with a search field over a flat list of modes. Each row is a shield glyph +
/// label with a trailing checkmark on the current selection — paseo renders its
/// permission menu exactly this way (searchable, one glyph per mode, a checkmark
/// on the active mode); this is the native translation.
///
/// Backed by a `Binding<String>` (the persisted `PermissionPolicy.rawValue`
/// from `ChatDetailView`'s `@AppStorage`) rather than owning storage, so the composer
/// stays the single source of truth for the app-wide default.
struct PermissionModeSelector: View {
    @Binding var rawValue: String

    @State private var isPresented = false
    @State private var searchText = ""
    @State private var hovered: PermissionPolicy?
    @State private var isHovered = false

    /// The selected policy (falls back to bypass — the persisted default — if
    /// the raw value is somehow unknown).
    private var current: PermissionPolicy {
        PermissionPolicy(rawValue: rawValue) ?? .bypass
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            trigger
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            popoverContent
        }
        .help(current.help)
    }

    // MARK: - Trigger chip

    /// The compact chip: glyph + label + chevron. Styled to match
    /// `ProviderSelector`'s trigger (`.callout` + primary fill) so the two
    /// read as sibling chips in the composer toolbar. A subtle hover bubble
    /// (matching the popover-row idiom) signals clickability.
    private var trigger: some View {
        HStack(spacing: 4) {
            Image(systemName: current.glyph)
                .foregroundStyle(.primary)
            Text(current.label)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.primary)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Popover (search + flat list)

    private var popoverContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeList
        }
        .frame(width: 230)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            TextField("Search modes", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// The modes after applying the search filter (matches the label,
    /// case-insensitive). Empty query = all modes.
    private var filteredModes: [PermissionPolicy] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return PermissionPolicy.allCases }
        return PermissionPolicy.allCases.filter { $0.label.lowercased().contains(query) }
    }

    /// A plain content-hugging column of rows (no `List`, which reserves a large
    /// fixed height and leaves the popover oversized). With only a handful of
    /// modes it never scrolls; the cap is a safety net.
    private var modeList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(filteredModes, id: \.self) { mode in
                    row(mode)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: modeListHeight)
    }

    /// Hug the rows: row count × row height, capped so a (hypothetical) long
    /// filtered list scrolls instead of growing without bound.
    private var modeListHeight: CGFloat {
        let rowHeight: CGFloat = 28
        let count = max(filteredModes.count, 1)
        return min(CGFloat(count) * rowHeight + 8, 240)
    }

    /// One row: shield glyph + label + a checkmark when selected, with a hover
    /// highlight. Mirrors `ProviderSelector.rowView` so the two dropdowns match.
    private func row(_ mode: PermissionPolicy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mode.glyph)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(mode.label)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
            if mode == current {
                Image(systemName: "checkmark")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered == mode ? Color.primary.opacity(0.08) : .clear)
                .padding(.horizontal, 4)
        )
        .onHover { inside in
            if inside { hovered = mode } else if hovered == mode { hovered = nil }
        }
        .onTapGesture { select(mode) }
    }

    private func select(_ mode: PermissionPolicy) {
        rawValue = mode.rawValue
        isPresented = false
        searchText = ""
    }
}

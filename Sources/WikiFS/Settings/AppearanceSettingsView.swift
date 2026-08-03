import SwiftUI

/// User-selectable per-app appearance override.
///
/// Stored as a raw string in `@AppStorage("appearance.mode")` so the choice
/// persists across launches. `.system` defers to the OS appearance.
enum AppearanceMode: String, CaseIterable {
    case light
    case dark
    case system

    /// The SwiftUI `ColorScheme` to apply via `.preferredColorScheme`.
    /// `nil` means "follow the system" (no override).
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    /// The AppKit `NSAppearance.name` for `NSApp.appearance`, so AppKit-level
    /// surfaces (NSAlert, menu bar, status item) also honor the override.
    /// `.system` returns `nil` (clears `NSApp.appearance`, follows OS).
    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .light: return .aqua
        case .dark: return .darkAqua
        case .system: return nil
        }
    }

    /// Convenience: resolves the current `@AppStorage` raw value, falling back
    /// to `.system` when unset or invalid.
    static func from(rawStorage raw: String?) -> AppearanceMode {
        guard let raw else { return .system }
        return AppearanceMode(rawValue: raw) ?? .system
    }
}

/// Settings ▸ **Appearance** tab: lets the user override the app's color
/// scheme (Light / Dark / System) independently of the OS setting.
///
/// The override is applied app-wide in `WikiFSApp` via
/// `.preferredColorScheme` (SwiftUI windows) and `NSApp.appearance`
/// (AppKit surfaces — NSAlert, menu bar, status item). The WKWebView reader
/// follows automatically via its CSS `color-scheme: light dark` property.
struct AppearanceSettingsView: View {
    @AppStorage(AppearanceSettingsView.storageKey) private var modeRaw = AppearanceMode.system.rawValue

    /// The `@AppStorage` key shared with `WikiFSApp` so both the picker and
    /// the root scene read/write the same `UserDefaults` value.
    static let storageKey = "appearance.mode"

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: modeBinding) {
                    Label("Light", systemImage: "sun.max")
                        .tag(AppearanceMode.light)
                    Label("Dark", systemImage: "moon")
                        .tag(AppearanceMode.dark)
                    Label("System", systemImage: "circle.lefthalf.filled")
                        .tag(AppearanceMode.system)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows your macOS appearance setting. "
                     + "Light or Dark overrides it for this app only.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bridges `@AppStorage(String)` → `AppearanceMode` for the `Picker`.
    private var modeBinding: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: modeRaw) ?? .system },
            set: { modeRaw = $0.rawValue }
        )
    }
}

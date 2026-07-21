# Plan: Appearance Settings Tab

## Goal
Add an "Appearance" tab to the Settings window that lets the user choose Light, Dark, or System appearance for the app. This is a per-app override (independent of the OS setting).

## Current state

### Settings tabs (`Sources/WikiFS/Window/WikiFSApp.swift`)
Three tabs exist: `.zotero`, `.extraction`, `.agents` (enum `SettingsTab` at line ~527). No appearance tab.

### No existing appearance override
The app currently follows the system appearance. There's no `preferredColorScheme` or `NSRequiresAquaSystemAppearance` override anywhere.

## Implementation

### 1. Add `SettingsTab.appearance`
```swift
enum SettingsTab: String {
    case zotero
    case extraction
    case agents
    case appearance  // NEW
}
```

### 2. Add the tab to the TabView
```swift
AppearanceSettingsView()
    .tag(SettingsTab.appearance)
    .tabItem { Label("Appearance", systemImage: "paintbrush") }
```

### 3. Create `AppearanceSettingsView` (new file)
`Sources/WikiFS/Settings/AppearanceSettingsView.swift`:

```swift
struct AppearanceSettingsView: View {
    @AppStorage("appearance.mode") private var modeRaw = AppearanceMode.system.rawValue

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: $mode) {
                    Label("Light", systemImage: "sun.max").tag(AppearanceMode.light)
                    Label("Dark", systemImage: "moon").tag(AppearanceMode.dark)
                    Label("System", systemImage: "circle.lefthalf.filled").tag(AppearanceMode.system)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: modeRaw) ?? .system },
            set: { modeRaw = $0.rawValue }
        )
    }
}

enum AppearanceMode: String, CaseIterable {
    case light
    case dark
    case system

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}
```

### 4. Apply the appearance to the app
In `WikiFSApp` (the main app view), apply `preferredColorScheme` based on the stored appearance mode:

```swift
// In the root scene view:
@AppStorage("appearance.mode") private var appearanceModeRaw = AppearanceMode.system.rawValue
// ...
.preferredColorScheme(AppearanceMode(rawValue: appearanceModeRaw)?.colorScheme)
```

### 5. WKWebView appearance sync
The reader's WKWebView CSS already matches light/dark via `color-scheme` CSS property (`WikiReaderView.swift:186`). When the app overrides the appearance, the web views should follow — verify the CSS `color-scheme` variable updates on `preferredColorScheme` change.

## Files to modify/add
| File | Change |
|---|---|
| `Sources/WikiFS/Settings/AppearanceSettingsView.swift` *(new)* | The appearance picker view |
| `Sources/WikiFS/Window/WikiFSApp.swift` | Add `SettingsTab.appearance`; add tab to TabView; apply `.preferredColorScheme` to root |

## Acceptance criteria
- [ ] An "Appearance" tab appears in Settings with a paintbrush icon.
- [ ] Three options: Light, Dark, System (radio group).
- [ ] Selecting Light makes the app light-mode immediately.
- [ ] Selecting Dark makes the app dark-mode immediately.
- [ ] Selecting System follows the OS appearance.
- [ ] The WKWebView reader content matches the selected appearance.
- [ ] The selection persists across app launches (`@AppStorage`).
- [ ] `make build && make test` passes.
- [ ] No `print`; no bare `try?`.

## Gotchas
1. **`preferredColorScheme` placement**: apply it on the outermost view (the root WindowGroup content or the root scene), not on individual views. This ensures the whole app (including sheets, menus, status item) follows the override.
2. **macOS Settings window**: the Settings `TabView` window itself may not respect `preferredColorScheme` from the app root — it's a separate window. The appearance override should be applied broadly enough to cover both the main window and the settings window.
3. **macos-design skill**: consult `docs/skills/macos-design/SKILL.md` for the radio group picker pattern. Keep it simple — a grouped Form with a Section.
4. **`NSApp.appearance`**: for full app-wide coverage (including NSAlert, menu bar), you may also want to set `NSApp.appearance = NSAppearance(named: ...)` in addition to `.preferredColorScheme`. This ensures AppKit-level windows also match.
5. **No file overlap**: no running agents touch WikiFSApp.swift or the Settings views.

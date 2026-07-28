---
timestamp: 2026-07-20T001024Z
title: "Split Permissions into its own Settings tab"
branch: null
status: historical
timestamp_source: git-commit
---

# Split Permissions into its own Settings tab

## Progress


**Why:** The Agents tab (`AgentsSettingsView`) held both `providersSection`
and `permissionSection` in one `Form`. With >~3 providers, the inner `List`
on a `.frame(maxHeight: 220)` plus the permission `Picker`s exceeded the
window height, the `Form` did not scroll, and the permission section was
clipped out of view — invisible to the operator.

**What changed:**

- **`Sources/WikiFS/Settings/PermissionsSettingsView.swift`** (new) — host
  for the three permission-mode `Picker`s (Chat / Ingest / Lint). Plain
  `Form { Section { ... } header: "Permissions" footer: ... }
  .formStyle(.grouped)`, mirroring `GeneralSettingsView`. Same three
  `@AppStorage(AgentLauncher.PermissionModeKey.<x>)` bindings as before —
  the keys are view-independent (`UserDefaults`), so moving the bindings
  into a new view is a pure refactor, not a migration.
- **`Sources/WikiFS/Window/WikiFSApp.swift`** — added `case permissions` to
  `SettingsTab` and a new `TabView` entry:
  `PermissionsSettingsView().tag(.permissions)
  .tabItem { Label("Permissions", systemImage: "lock.shield") }`.
- **`Sources/WikiFS/Settings/AgentsSettingsView.swift`** — removed the
  `permissionSection` computed property, removed its three now-unused
  `@AppStorage` vars (`chatModeRaw` / `ingestModeRaw` / `lintModeRaw`),
  and dropped `permissionSection` from the body. Also dropped the
  `.maxHeight: 220` cap from the providers `List`'s `.frame(...)` so the
  list can grow with content (the outer `Form` with `.formStyle(.grouped)`
  scrolls natively when the section exceeds the window). `$selectedProviderID`
  selection on the `List` is preserved (the Add/Delete/Make Default/Edit
  toolbar relies on it).

**No test changes** — the existing `AgentsSettingsViewModelStatusTests` /
`AgentsSettingsViewWarningTests` only exercise the `nonisolated static`
`modelStatus(for:in:)` / `modelWarning(for:in:)` classifiers, neither of
which was touched. No test previously rendered `permissionSection`.

**Result:** 260 suites / 3064 tests pass. `swift build` clean.

**Build:** `make version prompts && swift build && swift test`.

---

## Verification

Historical verification remains in the progress record above.

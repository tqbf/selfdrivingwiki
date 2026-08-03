# Composer Styling Plan

## Goal

De-grey the chat composer controls and add hover affordances so the model selector, bypass control, and plus button are more visible and interactive.

**Changes:**
1. Model selection (ProviderSelector) → normal-strength text (`.primary`) + hover background
2. Bypass control (PermissionModeSelector) → normal-strength text (`.primary`) + hover background
3. Plus button (AddContextPicker) → normal-strength icon (`.primary`) + hover background

**Scope:** Minimal styling changes only — no behavior changes, no re-layout, no new controls.

---

## Location

The composer is in `Sources/WikiFS/Chats/ChatView.swift`:
- **Main composer view:** `composer(enabled:)`
- **Toolbar row:** `composerToolbar(sendActive:)`

The toolbar hosts three controls in an `HStack`:
1. **Plus button:** `AddContextPicker(store:store) { … }`
2. **Model selector:** `ProviderSelector(launcher: launcher)`
3. **Bypass control:** `PermissionModeSelector(rawValue: $permissionModeRaw)`

---

## Control 1: Model Selection (ProviderSelector)

**File:** `Sources/WikiFS/Settings/ProviderSelector.swift`
**Location:** `trigger` view

**Fix:**
- Change `.foregroundStyle(.secondary)` on the label → `.foregroundStyle(.primary)`
- Change `.foregroundStyle(.tertiary)` on the chevron → `.foregroundStyle(.primary)`
- Add `@State private var isHovered = false`
- Add hover background with `Color.primary.opacity(0.08)` RoundedRectangle(cornerRadius: 6)
- Add `.onHover { isHovered = $0 }` and `.animation(.easeInOut(duration: 0.15), value: isHovered)`

## Control 2: Bypass Control (PermissionModeSelector)

**File:** `Sources/WikiFS/Settings/PermissionModeSelector.swift`
**Location:** `trigger` view

**Fix:** Same approach — change `.secondary`/`.tertiary` → `.primary` on glyph, label, chevron; add hover background.

## Control 3: Plus Button (AddContextPicker)

**File:** `Sources/WikiFS/Editor/AddContextPicker.swift`
**Location:** Button label in `body`

**Fix:** Change Image `.foregroundStyle(.secondary)` → `.foregroundStyle(.primary)`; add hover background.

---

## Existing Hover Idiom

The app uses a consistent hover pattern for list rows:
- `Color.primary.opacity(0.08)` background
- `RoundedRectangle(cornerRadius: 6)`
- Examples in `ProviderSelector.rowView`, `PermissionModeSelector.row`, `AddContextPicker.row`

We match this idiom on the trigger chips, with `.easeInOut(duration: 0.15)` animation.

---

## Testing

Manual UI validation: launch app, open chat composer, verify in light + dark mode that:
- Text/icons render at full-strength primary color (not greyed)
- Hover shows the bubble background on each control
- Popovers still open correctly
- Toolbar layout unchanged

```bash
make build && make test
```

## Acceptance Criteria

- [ ] Model selector text is full-strength (white in dark / dark in light)
- [ ] Bypass control text is full-strength
- [ ] Plus button icon is full-strength
- [ ] All three controls show hover bubble
- [ ] Popover row hover unchanged
- [ ] Toolbar layout unchanged
- [ ] Build + tests pass

## Gotchas

- Use `.primary` (adapts to light/dark) — never hardcode `Color.white`/`Color.black`.
- PR #716 (agent-settings-tabs) merged and shifted line numbers in `ProviderSelector.swift` — locate the trigger view by content (`private var trigger: some View`).
- No `print()` (use `DebugLog`), no bare `try?`.

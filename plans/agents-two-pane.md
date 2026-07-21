# Plan: Agents Settings — Two-Pane Provider Layout

## Goal
Redesign the Agents settings view from a single-column VStack to a two-pane layout:
- **Left panel**: provider list (selectable, with Add/Remove/Edit actions)
- **Right detail pane**: the selected provider's details — command, env, API key, model, and the Chat/Ingestion/Lint/Summary stage pickers + helper text

This matches macOS System Settings → Accounts idiom (left list, right details).

## Current state (`Sources/WikiFS/Settings/AgentsSettingsView.swift` — 1237 lines)

### Layout (single column)
```
VStack {
    providersSection           ← List of providers + action bar
    operationTabsSection       ← Chat/Ingestion/Lint/Summary picker + StageProviderModelPicker rows
    helperText                 ← "Models you pick..." + "Providers are stored in agent-providers.json..."
}
```

### State
- `config: AgentProvidersConfig` — the provider config
- `selectedProviderID: String?` — the selected provider in the list
- `selectedOperationTab: OperationTab` — `.chat`/`.ingestion`/`.lint`
- `showAddSheet` / `editingProvider` / `isAddingNewProvider`
- `providerPendingDeletion` — confirmation flow

## Design

### New layout
```
HStack(spacing: 0) {
    // LEFT PANEL: provider list
    VStack {
        List(selection: $selectedProviderID) {
            ForEach(config.providers) { provider in
                ProviderRow(provider: provider, isSelected: provider.id == selectedProviderID)
            }
        }
        providerActionBar  // Add / Remove / Make Default / Edit
    }
    .frame(width: 240)

    Divider()

    // RIGHT PANEL: selected provider details
    ScrollView {
        if let provider = selectedProvider {
            ProviderDetailPane(...)
        } else {
            ContentUnavailableView("Select a provider", systemImage: "cpu")
        }
    }
}
```

### `ProviderDetailPane` (new view — right panel)
Shows the selected provider's configuration:
1. **Provider header**: name, enabled toggle, default badge
2. **Provider config**: command, env vars, API key (read-only, link to Edit sheet)
3. **Model selection**: the selected model dropdown, Refresh button
4. **Operation stage pickers**: the Chat/Ingestion/Lint/Summary tabs + StageProviderModelPicker rows
5. **Helper text**: "Models you pick..." + "Providers are stored in agent-providers.json..."

The `operationTabsSection` content moves INTO this pane.

## Implementation
1. Extract `ProviderDetailPane` (new view)
2. Rewrite `body` to two-pane HStack
3. Move `operationTabsSection` content into detail pane
4. Keep all existing functionality (Add/Remove/Edit/Default, sheets, model refresh)

## Acceptance criteria
- [ ] Left panel shows the provider list with selection.
- [ ] Right panel shows the selected provider's details.
- [ ] Chat/Ingestion/Lint/Summary tabs + StageProviderModelPicker rows are in the right detail pane.
- [ ] Helper text is in the right detail pane.
- [ ] Add/Remove/Edit/Default actions work from the left panel.
- [ ] Selecting a different provider updates the right pane.
- [ ] With no provider selected, the right pane shows an empty state.
- [ ] The window has a reasonable minimum size for the two-pane layout.
- [ ] `make build && make test` passes.
- [ ] No `print`; no bare `try?`.

## Gotchas
1. macOS-design: left panel ~240pt, sidebar list style.
2. swiftui-pro: List selection pattern.
3. `selectedProviderID` already exists.
4. Stage pickers are GLOBAL config, not per-provider.
5. No file overlap.

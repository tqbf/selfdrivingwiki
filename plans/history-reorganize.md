# Plan: Reorganize page history — date-first, better operation/agent labels

## Problem
The page version history (in the inspector's History tab) lists entries with a flat index number (`0`, `1`, `2`...) instead of a date, and the layout is: `index · activityKind · agentLabel · date · title`. The user wants:
1. **Date first** — each row should lead with the date, not an index.
2. **Better organized operation + agent** — the operation (import/edit) and who did it should be clearly labeled and grouped.

## Current state

### The query (`GRDBWikiStore.swift:4520`)
```sql
ORDER BY pv.id ASC;
```
Returns oldest-first (ULID ordering). The UI renders in this order.

### The rendering (`PageDetailView.swift:799-880`)
```swift
// originRow — the "Last saved by" header
HStack {
    "Last saved by" · agentLabel · "·" · activityKind · "·" · savedAt(relative) · "ago"
}

// historyRow — each entry
HStack {
    Text("\(idx)")           // ← flat index, not a date
    Text(entry.activityKind)  // "import" / "edit" — raw
    agentLabel(entry)
    "·"
    Text(entry.savedAt, style: .date)  // date, but THIRD
    if title not empty { "·" title }
}
```

### PageOrigin fields available (`PageOrigin.swift:19-78`)
- `versionID: String` (ULID)
- `title: String` (title at save time)
- `agentName: String` (`chat:<id>` / `agent:<kind>` / `user` / model id)
- `agentKind: String` (`chat` / `agent` / `human` / `model` / `software`)
- `activityKind: String` (`import` / `edit`)
- `runTitle: String?` (chat title for chat-backed saves)
- `savedAt: Date`

## Design

### 1. Change query to newest-first (`GRDBWikiStore.swift:4520`)
```sql
ORDER BY pv.id DESC;
```
Most recent version at the top — standard version history UX (like git log).

### 2. Redesign `historyRow` layout — date-first

Each row should read like a version timeline entry:

```
Jul 21, 2026 3:45 PM    [Edit]  Agent Name
Jul 21, 2026 2:12 PM    [Import]  Agent Name
Jul 20, 2026 9:00 AM    [Edit]  Chat: "Some Chat Title"
```

New layout:
```swift
HStack(alignment: .firstTextBaseline, spacing: 8) {
    // Date — leading, fixed-width for alignment
    Text(entry.savedAt, format: .dateTime.month().day().year().hour().minute())
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 140, alignment: .leading)

    // Operation badge
    operationBadge(entry.activityKind)

    // Agent label (existing agentLabel helper)
    agentLabel(entry)

    Spacer()

    // Title at save time (if different from current title)
    if entry.title.isEmpty == false {
        Text(entry.title)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
```

### 3. Operation badge (`PageDetailView.swift`)
A small colored badge for the activity kind, making it scannable:

```swift
@ViewBuilder private func operationBadge(_ kind: String) -> some View {
    let label = kind.capitalized  // "Import" / "Edit"
    let color: Color = kind == "import" ? .blue : .green
    Text(label)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(color)
}
```

### 4. Remove the flat index number
The index (`0`, `1`, `2`...) is meaningless to the user. The date replaces it as the leading column.

### 5. Keep the origin header but simplify
The `originRow` (last saved by) is fine as a summary header above the list. Keep it but make it match the new date-first style:

```swift
HStack {
    Text("Last saved")
        .foregroundStyle(.secondary)
    Text(origin.savedAt, format: .dateTime.month().day().year().hour().minute())
        .foregroundStyle(.secondary)
    operationBadge(origin.activityKind)
    agentLabel(origin)
}
```

### 6. Make rows clickable (preserve #745 behavior)
The `handleProvenanceTap` is already wired. Keep it.

## Files to modify
| File | Change |
|---|---|
| `Sources/WikiFSCore/Store/GRDBWikiStore.swift` | Change `ORDER BY pv.id ASC` → `DESC` (newest-first) |
| `Sources/WikiFS/Pages/PageDetailView.swift` | Redesign `historyRow` + `originRow` in ProvenancePanel; add `operationBadge` helper |

## Acceptance criteria
- [ ] History entries are **date-first** (date is the leading column).
- [ ] History is **newest-first** (most recent at top).
- [ ] Each row shows the operation (Import/Edit) as a clear badge.
- [ ] Each row shows the agent (chat title / agent kind / user) clearly.
- [ ] The flat index number is removed.
- [ ] The title-at-save-time is shown (secondary/tertiary) when different from current.
- [ ] Rows are still clickable (#745 — navigate to chat/activity).
- [ ] `make build && make test` passes.
- [ ] No `print`; no bare `try?`.

## Gotchas
1. **`ORDER BY pv.id DESC`** — ULIDs are time-ordered, so DESC = newest-first. This is correct.
2. **Date formatting** — use `.dateTime.month().day().year().hour().minute()` for a compact but readable format. Use `.monospacedDigit()` for alignment.
3. **Fixed-width date column** — use `.frame(width: 140, alignment: .leading)` so dates align in a column. Adjust width if needed.
4. **The `idx` parameter** is no longer needed in `historyRow` — remove it from the `ForEach` call too.
5. **macos-design skill** — consult `docs/skills/macos-design/SKILL.md` for the badge style. Keep it simple — a rounded rect background with the operation color.
6. **swiftui-pro skill** — consult `docs/skills/swiftui-pro/SKILL.md` for the HStack alignment (`.firstTextBaseline`) and `.frame` usage.
7. **No file overlap** — #780 (linux-ci) touches ci.yml; #784 (inspector panel) is merged. This PR only touches PageDetailView.swift + GRDBWikiStore.swift.

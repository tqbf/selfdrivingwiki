# Plan: Migrate stored system prompts to use bare `wikictl` instead of `$WIKICTL`

## Problem
The default system prompt (`prompts/system-prompt-default.md`) was already updated to say "Invoke it as a bare `wikictl`" and use `wikictl page add` (not `page upsert`). But existing wikis have an OLD version of the system prompt stored in their `system_prompt` table (seeded from the old default). The agent still sees `$WIKICTL` in its staged AGENTS.md, and `$WIKICTL` doesn't always resolve correctly in the agent's shell (it mentions "AGENTS.md hints not matching the actual executable").

## Root cause
- `system_prompt` table (`GRDBWikiStore.swift:2291`) stores the user-editable prompt, seeded from `SystemPrompt.defaultBody` on wiki creation.
- `INSERT OR IGNORE` means existing wikis keep their old prompt forever — no migration updates it.
- The old prompt says **"Always invoke it as `$WIKICTL`"** (line 199 of the staged AGENTS.md) and **"`$WIKICTL page upsert`"** — but the new default says **"Invoke it as a bare `wikictl`"** and **"wikictl page add"**.
- The `WIKICTL` env var IS set (`ACPBackend.swift:1690`: `env[wikictl] = cli.wikictlDirectory + "/wikictl"`), and `wikictl` is on `PATH` (`:1692`). So `$WIKICTL` *should* work — but some agents/shells may not expand `$VAR` in certain contexts (e.g. subprocess without a login shell), making bare `wikictl` more reliable.

## Fix: v40 → v41 migration

Add a migration step in `GRDBWikiStore.migrate(from:in:)` that:
1. Reads the stored `system_prompt` body.
2. Replaces `$WIKICTL` → `wikictl` (regardless of context — the bare command is always correct since PATH includes the wikictl directory).
3. Replaces `wikictl page upsert` → `wikictl page add` (after the $WIKICTL→wikictl replacement).
4. Updates the stored body with the replaced text.
5. Only runs if the body contains `$WIKICTL` (idempotent — skip already-migrated prompts).
6. Bumps `user_version` to 41.

### The migration code (in `Sources/WikiFSCore/Store/GRDBWikiStore.swift`)

After the existing `if version < 40 { ... }` block, add:

```swift
if version < 41 {
    // v40→v41: migrate stored system prompts from $WIKICTL → wikictl.
    // The default prompt was updated to use bare `wikictl` (on PATH), but
    // existing wikis still have the old $WIKICTL instructions from when
    // they were seeded. $WIKICTL doesn't always expand correctly in the
    // agent's subprocess shell.
    let row = try Row.fetchOne(
        db,
        sql: "SELECT body_markdown FROM system_prompt WHERE id = 1;")
    if let body = row?["body_markdown"] as String?,
       body.contains("$WIKICTL") {
        let migrated = body
            .replacingOccurrences(of: "$WIKICTL", with: "wikictl")
            .replacingOccurrences(of: "wikictl page upsert", with: "wikictl page add")
        try db.execute(
            sql: "UPDATE system_prompt SET body_markdown = ?, updated_at = ? WHERE id = 1;",
            arguments: [migrated, Date.timeIntervalSinceReferenceDate])
    }
    try db.execute(sql: "PRAGMA user_version = 41;")
    version = 41
}
```

## Files to modify
| File | Change |
|---|---|
| `Sources/WikiFSCore/Store/GRDBWikiStore.swift` | Add v40→v41 migration step; bump `currentSchemaVersion` from 40 to 41 |

## Acceptance criteria
- [ ] On opening an existing wiki with `$WIKICTL` in its stored system prompt, the prompt is migrated to use bare `wikictl`.
- [ ] `page upsert` references in the stored prompt are changed to `page add`.
- [ ] The migration is idempotent (running on an already-migrated prompt is a no-op).
- [ ] New wikis are unaffected (they seed from the already-correct default).
- [ ] `swift test` passes (including any DB migration tests).
- [ ] `make build && make test` passes.

## Gotchas
1. **The `#129` emit rule** — this migration runs inside `migrate(from:in:)` which is NOT a public mutator. It runs during DB initialization, before the store is usable. No `ResourceChangeEvent` needed — the File Provider hasn't started observing yet. This is the same pattern as every other migration step.
2. **SQLite concurrency** — the migration runs inside `migrateIfNeeded(_:)` which is called during `init(databaseURL:)`. This is within the store's own write path, so it's naturally serialized.
3. **Don't touch the default prompt** — `prompts/system-prompt-default.md` is already correct. This migration only fixes *stored* prompts in existing DBs.
4. **The `wiki_index` table** has the same pattern (seeded from default, user-editable). But it doesn't reference `$WIKICTL`, so no migration needed for it.
5. **Don't break the `$WIKICTL` env var** — the env var is still SET by `ACPBackend.buildAgentEnv` (`:1690`). The bare `wikictl` works because it's on PATH. The migration only changes the *prompt text* that tells the agent which invocation to use — the underlying env var stays as a fallback.

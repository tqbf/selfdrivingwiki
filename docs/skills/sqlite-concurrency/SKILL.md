---
description: The hard rule for this app's SQLite layer — one connection, main-thread-only — and how to design UI/UX (blocking modal upgrades, main-thread writes, off-main only for pure compute) around it. Read before adding anything that touches the store off the main actor.
---

# SQLite is single-threaded here: design around it

This app's `SQLiteWikiStore` keeps **one connection** with a **prepared-statement
cache keyed by SQL**, and it must be touched from the **main thread only**. That
is not a SQLite limitation — it is a property of *our* code. Ignoring it produced
two real, silent launch crashes (a clean `exit()` and an `EXC_BREAKPOINT` in
`String(cString:)`). This skill is the rule and the UI/UX shapes that follow.

> **Invariant: all `SQLiteWikiStore` access happens on the main actor. MLX/Metal
> inference and other pure compute may go off-main; SQLite never does.**

## Why one thread (the failure that proved it)

SQLite was opened with `SQLITE_OPEN_FULLMUTEX` (serialized mode), which makes
*individual* C API calls thread-safe. **That is not enough.** The store caches
prepared statements by SQL text (`statement(sql)` returns the same
`sqlite3_stmt*` for identical SQL). When two threads run the same query
concurrently they receive the **same statement handle** and interleave:

```
Thread A: sqlite3_column_text(stmt)  → pointer P into stmt's row buffer
Thread B: sqlite3_step(stmt)/reset   → stmt advances/clears, P now garbage
Thread A: String(cString: P)         → reads garbage → traps on invalid UTF-8
```

`FULLMUTEX` serializes each call, but it cannot protect the app *holding a column
pointer across calls* while another thread mutates the statement. The result is a
garbage read — bytes that aren't valid UTF-8 — and `String(cString:)` traps
(`EXC_BREAKPOINT`), or worse, silent corruption. The fix is structural: **never
let a second thread reach the connection.**

## The two crash signatures to recognize

- **Clean `exit()`, no `.ips`.** A C/C++ dependency's default error handler
  called `exit()` from a background task before any Swift `do/catch` could run
  (the MLX "Failed to load the default metallib" launch death). See
  `docs/skills/debugging-with-lldb/SKILL.md`.
- **`EXC_BREAKPOINT` in `String(cString:)` / `sqlite3_column_text`**, faulting
  thread on `com.apple.root.utility-qos.cooperative`, called from a detached
  `Task` that read a `TEXT` column. That is the concurrent-statement race above.

Both came from moving store/embedding work to a background "backfill." The lesson:
there is no background backfill anymore.

## How to design the UI/UX around it

### 1. Bulk work = a blocking modal upgrade, never a background task

When a one-time, potentially-slow operation must touch the whole store (re-index,
embed all content, a cutover/migration), run it as a **main-actor upgrade behind
a non-dismissible sheet**. While the sheet is up the upgrade is the **sole owner
of the store** — by construction there is no second thread and no race.

The shape used by the search-index upgrade (`WikiStoreModel.upgradeSearchIndex`):

```swift
@MainActor                       // ← all SQLite here
func upgradeSearchIndex() async {
    guard EmbeddingService.selectedEmbedderIdentifier() == .miniLMIdentifier else { return } // skip if no model
    await EmbeddingService.configure()
    let pageWork   = store.missingPageEmbeddingWork()      // main SQLite read
    let sourceWork = store.missingSourceEmbeddingWork()    // main SQLite read
    guard pageWork.count + sourceWork.count > 0 else { return }   // warm DB → no sheet
    searchUpgrade = SearchUpgradeState(total:…)            // presents the sheet

    for (id, text) in pageWork {
        let blobs = await embedChunksOffMain(text)         // MLX off-main, NO SQLite
        try? store.storePageChunks(id: id, chunks: blobs)  // main SQLite write
        searchUpgrade?.done += 1                            // live progress
        await Task.yield()                                  // keep the spinner animating
    }
    // …same for sources…
    searchUpgrade = nil                                     // dismisses the sheet
}

/// Pure compute — touches NO SQLite. This is the ONLY thing that may go off-main.
private nonisolated func embedChunksOffMain(_ text: String) async -> [Data] {
    await Task.detached(priority: .utility) { EmbeddingService.chunkedEmbeddings(for: text) }.value
}
```

```swift
// ContentView — non-dismissible sheet bound to the upgrade state
.sheet(isPresented: Binding(get: { store.searchUpgrade != nil }, set: { _ in })) {
    SearchUpgradeView(store: store).interactiveDismissDisabled()
}
```

UX rules for the sheet:
- **Truly block.** `.interactiveDismissDisabled()` + a no-op binding setter, so
  only the model can end it. A dismissible sheet leaks interaction to the window
  behind it and reopens the race.
- **Show progress.** "N of M" + a `ProgressView`. The upgrade yields between docs
  so the spinner animates even though SQLite is main-thread.
- **Be a no-op when there's no work.** The common launch has nothing to upgrade →
  no sheet, instant. The sheet only appears on first run, an embedder cutover, or
  out-of-band (`wikictl`) writes.
- **Skip when the fast path is unavailable.** If the only embedder is the slow
  one (no MiniLM model bundled), do NOT block for minutes — fall back to FTS and
  run the upgrade when a fast embedder is present.

### 2. Incremental content = embed inline at write time, on the main actor

Don't accumulate "missing" content to catch up later. The write path embeds its
own content synchronously (page upsert → `storePageChunks`; source markdown →
`reembedSource`). That keeps the launch upgrade a rare, mostly-empty event and
makes new content searchable immediately. Because the write happens on the main
actor, it's single-threaded by definition.

### 3. Off-main is allowed ONLY for pure compute

`Task.detached` / `DispatchQueue` may run things that **never touch the store**:
MLX/Metal inference, the markdown linter's `JSContext`, `URLSession` fetches. The
test for whether something may go off-main: *does it call any `store.*` method,
`sqlite3_*`, or read a `SQLiteStatement`?* If yes → main actor only.

## Verifying the invariant

Before merging anything near the store:

```sh
# No detached task / dispatch queue / thread should reference the store connection.
grep -rnE "Task\.detached|DispatchQueue|Thread\." Sources/WikiFSCore/WikiStoreModel.swift Sources/WikiFSCore/WikiManager.swift
# Every store.* call must be inside a @MainActor method (the model is @MainActor).
grep -rnE "store\.(listPages|upsert|storePageChunks|storeSourceChunks|missingPage|missingSource|searchSimilar|page|source)" Sources/WikiFSCore/WikiStoreModel.swift
```

If a detached closure is found, open it: it must contain **only** pure compute
(`EmbeddingService.*`, JS, networking) and zero `store.*` / `sqlite3` calls.

## Defense in depth (still required)

Even with single-threaded access, DB text can contain arbitrary bytes (genuinely
bad data, or a future regression). Column readers must never trap:

- ✅ `String(bytes: ..., encoding: .utf8) ?? String(decoding: ..., as: UTF8.self)`
  (byte-length, lossy fallback, handles embedded NULs) — as `SQLiteStatement.text(at:)` does now.
- ❌ `String(cString:)` — traps on invalid UTF-8 and stops at an embedded NUL.

## Anti-patterns to avoid

- **Any background "backfill" / "indexer" task** that reads or writes the store.
  This is exactly what crashed twice; it is gone and must stay gone.
- **A dismissible or non-blocking progress UI** for store-wide work — it lets the
  user trigger store access concurrent with the work.
- **`Task.detached { store.X() }`** or `DispatchQueue.global().async { store.X() }`
  for any `X` that touches SQLite, "just to get it off the main thread."
- **`String(cString:)` on a DB column** — use the byte-length lossy decode.
- **Adding a `.sheet`/modifier that pushes a SwiftUI `body` over the type-checker's
  budget.** Split the view into `@ViewBuilder` computed properties (e.g.
  `baseContent`, `detailColumn`) rather than one giant expression.
- **Treating `SQLITE_OPEN_FULLMUTEX` as a license to share the connection across
  threads.** It serializes C calls; it does not protect app-level statement reuse.

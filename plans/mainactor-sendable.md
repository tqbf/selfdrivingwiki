# Plan: Explicitly mark URL & bookmark handlers @MainActor @Sendable (#739)

## Goal
Audit and add **explicit** `@MainActor @Sendable` annotations (where isolation is
currently inferred/implicit) to URL-click handlers and bookmark handlers that run
on the main actor and touch UI/store state. This makes isolation enforced at the
declaration site, so a future refactor that moves a closure across an actor
boundary produces a **compiler error** instead of a silent isolation change (or a
data-race warning/crash).

This is a **concurrency-correctness** change. READ the skill
`docs/skills/swift-concurrency-pro/SKILL.md` in your worktree first (see its
`actors`, `Sendable`, and `bug-patterns` references) and follow it — this project
is macOS 15 / Swift 6.0 (filter any version-gated guidance for newer toolchains).

## Scope (from issue #739)
Annotate the closures/functions that touch UI state or the store AND run on the
main actor, in:

**URL-click / in-app link routing:**
- `Sources/WikiFSLinks/WikiLinkMarkdown.swift` (the `OpenURLAction` closures / link
  scheme handling)
- The views that install them: `Sources/WikiFS/Window/ContentView.swift`,
  `Sources/WikiFS/Reader/WikiReaderView.swift`

**Bookmark handlers:**
- `Sources/WikiCtlCore/BookmarkCommand.swift`
- `Sources/WikiFSCore/Core/BookmarkNode.swift`
- `Sources/WikiFSCore/Core/BookmarkTreeBuilder.swift`
- `Sources/WikiFS/Bookmarks/` (BookmarksOutlineView.swift, BookmarksContainerView.swift,
  EditBookmarkSheet.swift, BookmarkTargetPickerSheet.swift)

## Guardrails (important — this is annotation, not behavior change)
1. **Only annotate what is actually main-actor-isolated.** Adding `@MainActor` to a
   type/func that genuinely runs off-main will either fail to compile or force an
   unwanted actor hop. Verify each candidate is currently main-actor (touches UI:
   View body, NSWindow, WKWebView main-thread APIs; or touches the `@MainActor`
   `WikiStoreModel`/store) before annotating. If a handler is off-main, add
   `@Sendable` only (no `@MainActor`) and a comment.
2. **Do NOT change runtime behavior.** An explicit annotation that matches the
   current inferred isolation should be a no-op at runtime. If adding an
   annotation changes hop behavior or fails to compile, STOP and prefer the smallest
   correct change (e.g., annotate the enclosing type, not each closure; or add
   ` @MainActor` to the `func` and let closures inherit).
3. **Prefer minimal annotations** that fix the most sites: e.g., marking a struct
   `@MainActor` propagates to its members without touching each. Don't over-annotate
   pure value types or DTOs that cross boundaries — those want `@Sendable` (or nothing)
   not `@MainActor`.
4. **Closures passed across boundaries** (escaping callbacks, `Task { }` captures,
   completion handlers) are the highest-value targets: an inferred-`@MainActor`
   closure captured into an escaping/Task context silently loses isolation.
5. **Every change must compile under `swift build`'s default (Swift 6 strict
   concurrency).** No introducing `nonisolated(unsafe)` as a workaround.
6. **No bare `try?`**; **no `print`** (use `DebugLog` if any diagnostic is needed).

## Acceptance
- `make build && make test` green under Swift 6 strict concurrency.
- URL-click handlers and bookmark handlers that run on the main actor and touch
  UI/store state have **explicit** `@MainActor @Sendable` (with a brief comment
  where a non-obvious decision was made, e.g. "off-main intentionally: <reason>").
- No runtime behavior change (the annotations match existing inferred isolation).
- No `nonisolated(unsafe)` introduced as a workaround.
- Manual sanity check in the running app (`make run`): click a `[[wiki-link]]`
  in a page (navigates) and open the Bookmarks view (loads tree) — both work.

## Build/test
`make build && make test`. Push the branch, open a PR with `Closes #739`. **Do NOT
merge to main.** Scratch in `tmp/` inside your worktree.

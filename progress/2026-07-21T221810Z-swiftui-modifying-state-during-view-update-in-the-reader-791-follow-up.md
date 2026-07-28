---
timestamp: 2026-07-21T221810Z
title: "SwiftUI \"Modifying state during view update\" in the reader (#791 follow-up)"
branch: null
status: historical
timestamp_source: git-commit
---

# SwiftUI "Modifying state during view update" in the reader (#791 follow-up)

## Progress


**Why:** Running the test suite in Xcode surfaced repeated runtime issues:
`Modifying state during view update, this will cause undefined behavior.`
Xcode attributed them to `PageDetailView.editorContent`, which was a red
herring — the write was three layers away, in `WikiReaderView`.

**Root cause:** `WikiReaderView.Coordinator.startLoad(markdown:isLoading:)`
did `isLoading.wrappedValue = true` synchronously. `startLoad` is called from
both `makeNSView` and `updateNSView`, i.e. from inside SwiftUI's update pass,
so every mount of the reader wrote `@State` mid-update. Because the reader is
embedded widely (and `PageDetailView` seeds `isEditing` in `.onAppear`, so the
reader branch renders on first paint even for a page opened in edit mode), one
defect produced warnings that looked scattered across unrelated suites.

**What changed:**

- **`Sources/WikiFS/Reader/WikiReaderView.swift`** — `startLoad` no longer
  writes the binding synchronously. It skips the write entirely when already
  loading (the first-mount case, where `isLoading` starts `true`) and otherwise
  hops to the next main-actor turn. Mirrors the existing precedent in
  `ComposerTextView.Coordinator.recomputeHeight` (#436), which already carried
  the comment "must never write synchronously, since this also runs from inside
  `updateNSView`" — the lesson had been learned once and not generalized.

- **`Sources/WikiFS/Editor/ScrollableTextEditor.swift`** — unrelated hardening
  for the same bug class, found while investigating (no test currently mounts
  the path, so it was not the reported warning). `makeNSView` now seeds
  `textView.string` before wiring the delegate; `updateNSView` brackets its
  programmatic `.string` sync and `setSelectedRange` with a new
  `isApplyingProgrammaticChange` flag that suppresses caret/text write-back.
  A heading jump still updates the outline highlight via a deferred report, so
  behavior is preserved.

**Detection method (worth keeping):** these are runtime issues, not compile
warnings — they never appear in a build log, and `swift test` does not display
them. They are `os_log` faults and can be captured from the CLI:

    /usr/bin/log stream --predicate \
      'subsystem == "com.apple.runtime-issues" and category == "SwiftUI"' \
      --style compact

Run that alongside the tests to get the same purple diamonds Xcode shows.
Note that `swift test` mounts hosted views without a window server, so some
suites never lay out and stay silent; xcodebuild renders for real and exposes
more. Verify UI fixes under xcodebuild.

**Result:** full xcodebuild test run went from 8 occurrences to 0; full
`swift test` (3358 tests / 279 suites) also 0. Bisected by stubbing
`PageDetailView`'s body; `PageDetailView.swift` itself is unchanged.

**Codified:** the invariant (never write SwiftUI state synchronously from a
representable's `makeNSView`/`updateNSView`, plus the defer/suppress fix
patterns) is now a rule in AGENTS.md; the detection + bisect procedure is a new
"SwiftUI runtime issues" section in
`docs/skills/reproducing-live-ui-bugs/SKILL.md`, whose `description` now also
advertises the runtime-issue case so it gets discovered.

**Build:** `swift build && swift test`.

## Verification

Historical verification remains in the progress record above.

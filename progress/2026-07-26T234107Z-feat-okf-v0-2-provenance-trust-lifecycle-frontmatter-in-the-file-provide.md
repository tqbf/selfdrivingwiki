---
timestamp: 2026-07-26T234107Z
title: "feat: OKF v0.2 provenance/trust/lifecycle frontmatter in the File Provider projection (#927)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: OKF v0.2 provenance/trust/lifecycle frontmatter in the File Provider projection (#927)

## Progress


**Scope.** The File Provider projection now emits OKF v0.2 frontmatter for
pages, source markdown siblings, and the bundle root `index.md`, replacing the
older ad hoc page/source keys where the OKF spec calls for standardized fields.

**Decisions.**
- Added typed OKF frontmatter models/serializer in
  `Sources/WikiFSCore/Markdown/OKFFrontmatter.swift` rather than appending
  stringly YAML at call sites.
- Pages now emit `type: "Page"`, `title`, `generated.by`, `generated.at`, and
  spec-compliant `sources` entries when `source_links` provides cited source
  concepts. We intentionally use only `.cite` links, dedupe by `PageID`, and
  point to projected related source concepts (`/sources/by-id/<id>.md`).
- Source markdown siblings now emit `type: "Source"`, `title`, `generated`,
  and a single OKF `sources` entry pointing at the projected raw source
  resource (`/sources/by-id/<id>.<ext>`), which is the truthful provenance we
  have today.
- Root `index.md` now wraps the persisted wiki index body in
  `okf_version: "0.2"` frontmatter per OKF bundle-root rules.
- Actor mapping is generated from existing typed data only: pages map known
  authors (`human:user`, `process:chat:<id>`, `process:agent:<kind>`,
  `process:legacy-import` fallback), and source markdown uses extraction
  producer name/version when available, otherwise a typed fallback derived from
  `SourceMarkdownOrigin`.
- We do **not** emit `verified`, `status`, or `stale_after`. The current model
  has no durable semantics that would make those claims truthful, so emitting
  them would fabricate trust/lifecycle state.

**Verification.**
- `make prompts version keychain` — passed.
- `swift build --build-tests` — passed.
- `swift test --filter 'PageMarkdownFormatTests|ProvenanceFrontmatterTests'` —
  passed.
- `swift test --filter 'ProjectionTests|ProjectionTreeTests'` — passed.
- Combined focused verification
  `swift test --filter 'PageMarkdownFormatTests|ProvenanceFrontmatterTests|ProjectionTests|ProjectionTreeTests'`
  — passed (78 tests in 4 suites).
- `git diff --check` — passed.
- `make lint` — passed, including the repo guard for new bare `try?`.
- `pre-commit run --all-files` — could not run on this machine because
  `pre-commit` is not installed (`zsh:1: command not found: pre-commit`).
- `swift test` (full suite) did **not** complete during verification. The run
  started at `2026-07-26 15:59:33 -0700`, stopped producing log output at
  `2026-07-26 16:00:29 -0700`, and remained live/idle in
  `swiftpm-testing-helper` on the main run loop with auxiliary Tantivy watcher
  threads visible in a `sample`. Captured artifacts:
  `tmp/issue-927-swift-test.log`,
  `tmp/issue-927-swift-test.sample.txt`,
  `tmp/issue-927-swiftpm-helper.sample.txt`.

**Plan:** [`plans/issue-927-okf-v0-2.md`](plans/issue-927-okf-v0-2.md).

## Verification

Historical verification remains in the progress record above.

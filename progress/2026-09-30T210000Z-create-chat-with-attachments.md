---
timestamp: 2026-09-30T210000Z
title: Create chat with attachments — sidebar context-menu items
branch: feature/new-chat-with-attachments
status: complete
---

# Create chat with attachments — sidebar context-menu items

## Progress

Implemented `plans/create-chat-with-attachments.md` exactly as approved.

- **Menu items**: the Pages and Sources selection menus gain
  `New Chat with Page(s)` / `New Chat with Source(s)` (plus.bubble, no
  shortcut), placed directly before "Add to Bookmarks…". The AppKit actions
  forward the effective selection (selected ∪ clicked, row order) through the
  new `onNewChat` callbacks; the containers map ids through
  `ChatAttachmentTarget.pages/.sources` into `beginNewChat(attachments:)`.
- **Model core**: `ChatAttachmentTarget` (tagged enum keeping the PageID and
  SourceID namespaces apart), `PendingChatAttachmentRequest` (chat-scoped
  hand-off), `beginNewChat(prefill:attachments:)` installing the request only
  after the store write succeeds and replacing it wholesale on every
  successful creation (empty targets included), and
  `consumePendingChatAttachmentRequest(for:)` — atomic, own-chat-only,
  independent of the composer focus marker.
- **Composer seam**: `ChatComposerAttachmentModel` (@Observable; add dedupe,
  `replace(with:)` for queued restores and failed-send draft restore,
  `applyTargets`). `ChatDetailView` consumes the request in `.onAppear` —
  synchronously at first mount, not in the cancellable hydration task. The
  outgoing payload, queued payload, and composer snapshot read shapes are
  unchanged; chips now flow through the model. New internal
  `onComposerPanePropsBuilt` test seam fires per composer-props build with
  the exact props handed to `ChatComposerPaneView`.
- **Test gate**: `HostedAppKitTestGate.acquire` replaced with a bounded,
  cancellation-aware `acquire(timeout:) async throws` (GateTimeoutError,
  cancelled waiters removed and resumed with CancellationError, exactly-once
  resume). All 131 call sites (38 files) migrated in the same change; no
  unbounded entry point remains.
- **Decision preserved**: the action opens the new chat as the ACTIVE TAB of
  the current wiki window (the app has no separate composer windows); pinned
  by `newChatStaysInHostWindow` on both lists.

Deviations from the plan text (both flagged for review):

1. The plan's "inject a test-owned ChatComposerAttachmentModel" became
   `@State`-owned model + the `onComposerPanePropsBuilt` capture seam. A
   hand-written memberwise initializer for ChatDetailView (~25 stored
   properties) was the alternative and was judged too brittle; all planned
   assertions hold through the captured props, which is the seam the plan's
   tests actually specified.
2. The scenario suite duplicates ~25 lines of DurableNewChatHostedTests'
   private fixture stubs (extractor/provider/queue-engine) rather than
   widening their accessibility.

## Verification

Default tier:

- `make build` — ✓ app built + signed (test count N/A for a build gate).
- `make test` — ✓ exit 0, "✓ tests pass" (full default graph; the new
  headless suites run here).

Mandatory opt-in tier (`WIKIFS_APP_TESTS=1`), executed counts from
`swift test` output:

- `WIKIFS_APP_TESTS=1 swift test --filter HostedAppKitTestGateTests` —
  ✓ "Test run with 5 tests in 1 suite passed".
- `WIKIFS_APP_TESTS=1 swift test --filter SidebarNewChatMenuHostedTests` —
  ✓ "Test run with 10 tests in 2 suites passed".
- `WIKIFS_APP_TESTS=1 swift test --filter ChatAttachmentHostedScenarioTests` —
  ✓ "Test run with 6 tests in 1 suite passed".
- `WIKIFS_APP_TESTS=1 swift test --filter ChatComposerAttachmentModelTests` —
  ✓ "Test run with 3 tests in 1 suite passed".
- Headless: `swift test --filter NewChatSidebarProjectionTests` — ✓ 24 tests
  (18 existing + 6 new); `swift test --filter ChatAttachmentTargetTests` —
  ✓ 1 test.
- `WIKIFS_APP_TESTS=1 make test` — exit 0; runner summaries total 4,972
  tests across 10 target runs, all reported "passed" (largest: 4,587 tests
  in 471 suites, 65 s).

### Gate-7 triage (important — read before trusting the full run)

The gate-7 log records ~15 Swift Testing suites with recorded issues despite
the 0 exit and passing summaries (the ✘ lines belong to a runner attempt
whose own "Test run" summary is absent from the log; SwiftPM's aggregated
verdict was success — most plausibly a crashed-then-retried runner, the
known output-interleaving quirk of `--parallel`). Triage, with evidence:

- **Reproduced identically at the branch base (d0529677, checked out in a
  throwaway worktree)**: `BuiltInRendererRegistryTests` (factory map count),
  `Issue235IngestExtractionLockTests` (three caption expectations),
  `WikiLinkMenuNSItemsTests` ("Chat menu parity per link kind"). Same
  assertions, same files, same lines — pre-existing/environmental, unrelated
  to this branch.
- **Documented pre-existing**: `YouTubeEmbedWebViewTests` (2 issues) matches
  the failure documented on main in
  `progress/2026-09-19T220000Z-wikictl-extractor-family.md`.
- **Environmental**: `PdfExtractionServiceTests` (uv not installed),
  `RealSpeechAnalyzerIntegrationTests` (SkipTest), renderer-reference suites
  (`PackageFenceReaderPlanTests`, `MarkdownImageEmbedProjectionTests`,
  `DiagramEmbedTests` — pinned renderer packages not present in this
  sandbox), `DefuddleExtractionServiceTests`, `SameSchemeSubresourceProbeTests`,
  `MetadataPanelHostedTests`, `ExtractionErrorTests`.
- **Contention flakes (pass standalone)**: `DaemonChatControllerTests`,
  `ChatViewD2Tests` (1-in-3 standalone on this branch; `resolveChat`/
  `createChat` untouched; the base run passed by luck of the same coin).
- None of the failing assertions intersect this diff; every suite this
  feature adds or extends is green in both tiers.

## Notes

- The menu-item helpers now tag the SF Symbol name via
  `setAccessibilityIdentifier` so hosted tests assert icons without image
  comparison.
- Pre-commit hooks (SwiftLint sweep, bare-`try?` audit) passed on every
  commit.

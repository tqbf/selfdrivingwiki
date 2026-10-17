---
timestamp: 2026-09-30T230000Z
title: Chat attachment persistence — chat_attachments table, bind/restore, restart proof
branch: feature/persist-chat-attachments
status: complete
---

# Chat attachment persistence — chat_attachments table, bind/restore, restart proof

## Progress

Implemented `plans/chat-attachment-persistence.md` (issue #1415) exactly as
approved, in 10 commits on `feature/persist-chat-attachments` (6 through the
original tip 8bb1b208 + 4 review-fix commits — `4dfaabc7`, `9d8710f7`,
`d9758804`, and this entry's docs commit).

- **Schema v57→v58** (`ccd2fe7c`): `createChatAttachmentsTableV58` (kind tag
  'page'|'source'|'chat' + raw ULID + position, FK cascade to `chats`,
  IF NOT EXISTS) runs in BOTH the ladder step and `createFreshSchema`'s
  inline chat block. New store surface: composed
  `createChat(kind:title:attachments:)` (chats row + attachment rows in ONE
  `mutate` savepoint — persist-first is atomic), `setChatAttachments`
  (replace-all, chatNotFound guard), `chatAttachments(chatID:)` ordered read
  with checked decode. Composition guard honored: the body uses only the
  non-emitting `insertChatLocked`/`insertChatAttachmentsLocked`
  Database-taking helpers (:484-496); both mutators classified in
  `StoreEmissionExhaustivenessTests`.
- **Write-through** (`2c94025f`): `ChatComposerAttachmentModel.bind(store:
  chatID:)` → `restoreFromStore()` (one nonpersisting deduped batch) →
  `armPersistence()`; after arming, every mutation performs exactly one
  `persistCurrentState()` write. `WikiStoreModel.setChatAttachments` is
  non-fatal (DebugLog.store; chips stay authoritative; next mutation
  retries).
- **Seam switch** (`8e65efc0`): `beginNewChat(attachments:)` routes through
  the composed overload; `PendingChatAttachmentRequest`,
  `pendingChatAttachmentRequest`, `consumePendingChatAttachmentRequest`, and
  `applyPendingChatAttachments` are REMOVED (zero references — audited);
  ChatDetailView's mount binds/restores/arms; the typed adapter and the
  projection-seam docs updated.
- **Tests** (`1658e2e9`): ChatAttachmentPersistenceTests (ordered
  write/replace, chatNotFound, checked decode, literal restart, rename
  identity, behavioral exactly-one/zero-event discipline, ABORT-trigger
  rollback proofs for composed create AND setChatAttachments),
  ChatAttachmentsMigrationTests (dropped-table v57 rewind → v58 preserving
  chats; fresh DB at v58), hosted chat-target restart + rename coverage,
  model bind/zero-write/draft tests, page/source/chat namespace triple.
- **AGENTS.md**: stale "currently at v53" schema line refreshed to v58.

## Verification

All gates PASS. Executed counts from `swift test` output:

- `make build` — exit 0, app built + signed (count N/A).
- `make test` — exit 0, "✓ tests pass".
- `WIKIFS_APP_TESTS=1 swift test --filter HostedAppKitTestGateTests` —
  ✓ 5 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter PagesNewChatMenuHostedTests` —
  ✓ 5 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter SourcesNewChatMenuHostedTests` —
  ✓ 5 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter
  ChatAttachmentHostedScenarioTests` — ✓ 8 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter
  ChatComposerAttachmentModelTests` — ✓ 7 tests (incl. the 4 parametrized
  write-through cases added by the review fix).
- Headless: ChatAttachmentPersistenceTests ✓ 9; ChatAttachmentsMigrationTests
  ✓ 2; NewChatSidebarProjectionTests ✓ 23; ChatAttachmentTargetTests ✓ 1;
  StoreEmissionExhaustivenessTests ✓ 7 (incl. the
  new classification).
- StoreConcurrencyTests ✓ 11 — TWO DISTINCT KINDS OF EVIDENCE: 9 pre-existing
  Phase-0 regression cases (method atomicity, savepoint nesting, rename
  atomicity — the pre-bump gate), PLUS the two NEW named AC.12 cases added
  by review fix: `concurrentAttachmentReadsVsReplacementsStayConsistent`
  (reads vs replacements never observe partial sets) and
  `attachmentMutatorsNestRollBackAndEmitUnderContention` (nest/rollback,
  nest/commit, and the injected ABORT-trigger failure under a contended
  reader — old rows intact, zero events on failure, the nested-emit escape
  pinned per the :484-496 hazard).
- `WIKIFS_APP_TESTS=1 make test` — first attempt exit 2:
  `quitBackstopKillsAnInFlightManagedOperation` (an 18s end-to-end
  quit-backstop test) failed under full-suite contention and PASSES in
  isolation (3.9s) — a load flake, not a regression; the same log
  interleaves the documented pre-existing/environmental set (renderer-package
  pins, uv/speech/defuddle). Rerun: exit 0, "✓ tests pass", 4,985 tests
  across the target summaries; the feature's suites are green in both
  tiers.

Schema-pin audit outcome: every `57` pin accounted for — the thirteen
"latest" pins across ChangeRevisionTests (:138), ChatStoreTests (:442),
FetcherStoreMigrationTests (:53-54,85,100), SchemaMigrationLadderTests
(:29,44,71,137,212), and WikiStrategyStoreTests (:85,100) now compare
against `GRDBWikiStore.schemaVersion`; the redundant literal
`schemaVersion == 57` in FetcherStoreMigrationTests was removed
(pragmaValue == schemaVersion already pins latest); the intentional
historical rewind stamps (`user_version = 56`) stay literal. Post-audit
grep: zero `== "57"` pins remain in Tests/.

## Notes

- **Deviation (small, tested)**: the rename scenario initially navigated
  with `openTab(.page)` + `openTab(.chat)`, which never remounts the
  surface — the tab switch keeps the chat view alive, so restore never
  re-ran and chips kept stale names. Fixed by closing the tab and reopening
  with a render pass between (genuinely remounts), bounded retries; the
  chatPayload scenario's reopen uses the same close+render-pass+reopen
  pattern.
- **Deviation (recorded)**: AC.11's real send/queue callbacks could not be
  driven in the CLI host — `isChatOperationConfigured` requires daemon
  provider config (`RemoteChatSession.providersConfig()`) and
  `runState.canSubmit` requires a live interactive session. Covered at the
  model seam instead (clear/replace write-through + restore paths are the
  exact code the callbacks call); the review-fix parametrized write-through
  test additionally pins send→clear→persist at the SQLite layer. Flagged
  for the reviewer.
- The temporary diagnostics instrumentation (restoreLog static) was removed
  before commit; the final tree has no probe code.

## Review fixes (round 2)

- `4dfaabc7` fix(store): `setChatAttachments` failures now surface through
  the same non-fatal `storeError` alert as the composed-create failure path
  (chips stay authoritative; next mutation retries).
- `9d8710f7` test(chat): the two named AC.12 `StoreConcurrencyTests` cases
  (see the StoreConcurrencyTests evidence line above) and the parametrized
  bound write-through test (remove/clear/replace/armed applyTargets, each
  asserting the resulting SQLite rows).
- `d9758804` test(chat): widened the AC.12 event-count poll to a bounded 5s
  after the first full-suite run flaked the dispatch-dependent assertions
  under load.

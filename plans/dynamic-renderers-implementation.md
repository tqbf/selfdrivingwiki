# Goal

Implement issue #1026 as a dependency-ordered PR series from updated `main`. Add one typed renderer registry for built-in native renderers and installed static WebView packages.

Use a Paseo orchestrator named **`dynamic-renderers-orchestrator`**. The orchestrator must complete registry routing, WebView isolation, Excalidraw, JSON Canvas, package management, tests, and documentation.

# Implementation Summary

Start from `main` after merged PR #1006. The branch must contain `plans/dynamic-renderers.md` and `plans/wiki-app-platform.md`.

Deliver seven focused PRs. Each PR must branch from its required predecessor and pass its merge gate before dependent work starts. The orchestrator can run independent research, tests, and reviews in parallel. It must not merge any PR to `main`; only the operator may merge.

Use these module boundaries:

- Put portable renderer IDs, references, descriptors, matchers, manifests, deterministic registry logic, the portable SHA-256 primitive, and the typed digest/lowercase-hex codec in `Sources/WikiFSTypes/Renderer/` or another appropriate `WikiFSTypes` subdirectory. `WikiFSTypes` must not depend on `WikiFSCore`.
- Put package validation, package installation records, and machine-scoped package storage in `Sources/WikiFSCore/Renderer/`.
- Put wiki enablement and renderer preferences in a dedicated GRDB table through `WikiStore`, `GRDBWikiStore`, and `WikiStoreModel`.
- Put WebKit session code, built-in view factories, JSON Canvas, and Excalidraw integration in `Sources/WikiFS/Renderer/`.
- Put renderer settings and package management in `Sources/WikiFS/Settings/`.
- Keep all format-specific routing out of `SourceDetailView`.

Use separate identifier types for package IDs, package versions, registration IDs, exact references, and logical references. Raw strings can cross only JSON, SQLite, package, and external-format boundaries.

Use a dedicated package resource URL scheme as the only WebView asset path. Use normalized manifests, deterministic asset ordering, and SHA-256 through the project hash helper. Reject duplicate paths, traversal, symlinks, unsupported files, undeclared files, missing files, and hash mismatches.

Enforce WebView isolation in layers:

1. Use `WKWebsiteDataStore.nonPersistent()` for every renderer session.
2. Serve the entry document and all validated assets through a custom `WKURLSchemeHandler`.
3. Make the scheme handler synthesize the entry response and attach the restrictive Content Security Policy as an HTTP response header before WebKit parses any package content.
4. Never load package HTML with `loadHTMLString` or a file or network base URL.
5. Make all executable and passive assets resolve only through the package scheme.
6. Use CSP to block subresource network APIs. Set `default-src`, `connect-src`, `img-src`, `media-src`, `font-src`, `frame-src`, `worker-src`, `object-src`, `form-action`, `base-uri`, and `navigate-to` where the deployed WebKit supports them.
7. Use `WKNavigationDelegate` to cancel disallowed top-level and frame navigation, redirects, forms, links, and `window.open`. Do not claim that this delegate intercepts all subresource requests.
8. Install the native message handler only in a named isolated content world. Use an isolated broker and a narrow `window.postMessage` protocol to communicate with package page code.
9. Require a per-session capability token, exact window and frame checks, unique request IDs, a closed method enum, payload limits, and cancellation during close.
10. Expose only typed `input.read` and declared link-navigation requests.
11. Require a user gesture before the host opens an external URL.
12. Remove all message handlers, delegates, scheme tasks, and transient references when the session closes.

Treat `HTMLSourceWebView` as a separate legacy presentation. Do not reuse its network-permitting configuration for renderer packages.

Use a dedicated wiki table instead of `wiki_metadata` JSON. The table must store per-wiki enablement and per-source logical or exact preferences with typed columns and constraints. Package payloads and installation records must stay outside wiki databases and File Provider projections.

Use system SwiftUI typography and native settings controls. Separate machine installation controls from current-wiki enablement controls. Keep renderer controls inside the rendered pane. Use progressive disclosure for diagnostics and rollback. Support keyboard navigation, VoiceOver, light and dark appearance, and Reduce Motion.

Do not add workers, package managers, network brokerage, credentials, writes, prompts, editable renderers, schedules, signing, or distribution.

# Implementation Plan

## Phase 0: Orchestrator setup and baseline

1. Create a Paseo worktree from updated `main` on a feature branch for the first PR.
2. Name the parent agent `dynamic-renderers-orchestrator` and preserve the approved Paseo role split: **Luna** is the orchestrator and integration owner, **Terra** performs bounded implementation and test work, and **Sol** performs independent risk-based review and exact-head audits. Do not let an implementation worker approve its own work.
3. Add labels such as `dynamic-renderers`, `issue-1026`, `orchestrator`, and the Luna/Terra/Sol role where Paseo supports labels.
4. Read `~/.paseo/orchestration-preferences.json` before selecting providers.
5. Read `PLAN.md`, `plans/dynamic-renderers.md`, `plans/wiki-app-platform.md`, and relevant files in `progress/`.
6. Confirm that PR #1006 is present in the branch history.
7. Capture an exact baseline record from updated `main`: commit SHA, Swift tools version, deployment target, current schema version, and the migration predecessor that PR 3 must extend. At review time these are expected to be Swift tools 6.0, macOS 26, schema v48, and next migration `current + 1` (currently v49), but derive and record the values instead of hardcoding them because `main` may advance. Preserve command-line SwiftPM support: `make build` and `make test` are primary, and prerequisite-synchronized bare `swift build` and `swift test` must remain valid without Xcode-only dependencies.
8. Run the existing focused renderer and source-detail tests as a baseline.
9. Use lower-power Terra agents for bounded mechanical work. Use stronger Terra agents for WebKit security and UI implementation, and independent Sol agents for specialist and final audits.
10. Require each worker to report changed files, changed production symbols, tests, risks, and remaining work.
11. Before implementation of each PR, create a retained, machine-readable test inventory that maps every changed production symbol and every decision and error branch to named tests. The inventory must identify success, error, boundary, cancellation, and teardown coverage where applicable. Reviewers must reject unmapped symbols or paths, and the test-coverage gate must pass before that PR can open.
12. Require each PR to use a Conventional Commit title.
13. Use branches `feature/dynamic-renderers-01-model` through `feature/dynamic-renderers-07-management`.
14. Base PR 1 on updated `main`. Base each later branch on the immediate predecessor branch.
15. Open each later PR against its immediate predecessor branch so its diff contains only that slice.
16. Treat a merge gate as passing tests, the per-PR test-coverage inventory, exact-head audit, and review. It does not authorize a merge; only the operator may merge.
17. Do not rebase or retarget a stacked PR after an operator merge unless the operator directs the orchestrator to do so.
18. Add a tracked Swift executable target at `Sources/DynamicRendererPRSeriesAudit/` and focused Swift Testing coverage at `Tests/DynamicRendererPRSeriesAuditTests/`. Declare both in `Package.swift`, so bare `swift test` and `make test` compile and run the audit tests. The executable checks ancestry with `git merge-base --is-ancestor`, inspects each three-dot diff, and queries GitHub PR base, title, checks, and review metadata. Exact invocation from the repository root is `swift run DynamicRendererPRSeriesAudit verify --series plans/dynamic-renderers-pr-series.json --evidence tmp/dynamic-renderer-gates`.
19. Track `plans/dynamic-renderer-gate-record.schema.json`, a versioned JSON Schema for one SHA-keyed gate record containing local audited SHA, `headRefOid`, required check-run names and SHAs, approval/review author and commit SHA, `baseRefName`, `baseRefOid`, clean-checkout proof, command results, test-inventory reference, finding dispositions, and record timestamp. Generate evidence under gitignored `tmp/dynamic-renderer-gates/<head-sha>.json`; validate every generated record against the tracked schema before accepting it. Track `plans/dynamic-renderers-pr-series.json` for the seven branch/base relationships and audit policy, not generated evidence.
20. Audit only a clean checkout of the exact head SHA. Rerun after every push and invalidate results when any bound SHA or base changes. Query GitHub again immediately before atomic evidence write and reject the write if head/base/check/review state changed.
21. Implement injected `GitRepositoryQuerying`, `GitHubPullRequestQuerying`, `GateRecordReading`, `GateRecordWriting`, and `AuditClock` seams. Add focused tests for stale local heads, wrong head or base refs/OIDs, check runs from another SHA, approvals on an older commit, dirty checkouts, force-push races, head/base changes between query and atomic write, schema rejection, and stale evidence reuse. Fail closed and require a clean exact-SHA rerun.
22. Implement `DynamicRendererBuildAndSuiteGate` as a second subcommand in the same executable. Exact invocation is `swift run DynamicRendererPRSeriesAudit build-suite --head <exact-head-sha> --evidence tmp/dynamic-renderer-gates`. It verifies a clean checkout at `<exact-head-sha>`, runs in order `make build`, `make test`, the repository’s documented opted-in app-test command, `make prompts`, `swift build`, and `swift test`, captures exit status and command provenance, validates the symbol/branch test inventory and any required mutation report, and atomically writes those results into that SHA’s schema-valid gate record. Any command failure or head change invalidates the gate.
23. At every phase and final gate, require no unresolved critical or high finding. Fix or explicitly rebut medium and low findings in retained SHA-keyed records. After any critical or high fix, rerun the relevant Sol specialist review and exact-head audit before dependent work starts.

## PR 1: Typed renderer model, matching, and package hash contract

Create the portable contract in `WikiFSTypes`.

1. Add separate files for:
   - `RendererPackageID`
   - `RendererPackageVersion`
   - `RendererRegistrationID`
   - `RendererReference`
   - `LogicalRendererReference`
   - `BuiltInRendererID`
   - `RendererImplementation`
   - `RendererPresentation`
   - `RendererMatcher`
   - `RendererDescriptor`
   - `RendererManifest`
   - compatibility, accessibility, link-policy, and size-limit value types
2. Make ID types `RawRepresentable`, `Codable`, `Hashable`, and `Sendable` where valid.
3. Define typed matcher cases for normalized MIME, extension fallback, bounded signatures, and artifact kinds.
4. Define a maximum sniff byte count as a named limit. Never let a matcher request unbounded source content.
5. Define explicit priority semantics and a stable tie-break key. Sort by priority, package ID, package version, and registration ID in a documented order.
6. Make registry selection independent of input and installation order.
7. Define exact and logical preference resolution. Prefer a compatible exact reference when present. Otherwise resolve a logical reference to the highest compatible installed version under the stable rules.
8. Define normalized manifest encoding with sorted keys, normalized relative paths, and deterministic asset order.
9. Move or create the project’s portable SHA-256 primitive in `WikiFSTypes`, together with a typed fixed-width digest and a strict canonical lowercase-hex codec. Deliberately migrate existing `WikiFSCore` hash callers to the portable API where needed; do not duplicate algorithms or create any `WikiFSTypes` to `WikiFSCore` dependency.
10. Define the package hash as SHA-256 over a versioned canonical envelope that includes the normalized manifest and every declared asset hash.
11. Reject duplicate registrations, duplicate paths, invalid IDs, unsupported manifest revisions, invalid presentation combinations, invalid limits, and capability requests outside the renderer contract.
12. Add fixtures for valid and invalid descriptors and manifests.
13. Add an API signature or compile-boundary test that prevents interchange of renderer ID namespaces and a package/import boundary test that proves `WikiFSTypes` imports on every supported platform without `WikiFSCore`.
14. Add named hash tests: `RendererSHA256Tests.testDigestBytes`, `RendererDigestHexCodecTests.testCanonicalLowercaseHex`, `RendererDigestHexCodecTests.testRejectsMalformedDigests`, `RendererPortableHashImportTests.testSupportedPlatformImports`, and `RendererPackageHashTests.testCanonicalEnvelopeGoldenDigestAndOrderIndependence`.
15. Run practical scoped mutation testing for the new pure digest codec, canonical envelope, matcher, priority, and preference-resolution logic in this PR. Classify survivors and fix or explicitly justify them before review; do not defer this scope to PR 7.

Merge gate: portable tests pass with bare `swift test` and the normal `make test` path; the PR 1 symbol/branch inventory, supported-platform import boundary, named hash suite, and practical scoped mutation report pass; and no review finding remains unresolved under the phase-wide policy.

## PR 2: Built-in registry snapshot and characterization adapters

Wrap existing source presentations without changing visible behavior.

1. Add `RendererRegistrySnapshot` as an immutable value.
2. Combine built-in descriptors and enabled installed descriptors through one initializer.
3. Add built-in descriptors for current renderable presentations. Include PDF, HTML, Mermaid, and media where their existing behavior maps to the renderer contract.
4. Keep Source outside renderer matching as the permanent host fallback.
5. Add a closed built-in factory map keyed by `BuiltInRendererID` in the app target.
6. Add an internal presentation planner that converts a source summary, bounded bytes, current markdown, and origin into registry inputs.
7. Characterize current `SourceDetailView` behavior before routing changes. Cover PDF, HTML, Mermaid, media, plain text, unknown content, and missing content.
8. Add a guard test that enumerates all `BuiltInRendererID` cases and requires one descriptor and one factory mapping.
9. Do not add Excalidraw or JSON Canvas yet.

Merge gate: golden characterization tests show no visible presentation regression.

## PR 3: Persistence for package records, wiki enablement, and preferences

Implement machine-scoped package records and wiki-scoped choices.

### Machine-scoped package record store and inactive index

1. Add a versioned renderer package directory under the resolved App Group container.
2. Reserve each package-ID/version directory for one immutable package version.
3. Store a versioned machine index with package identities, expected hashes, install state, diagnostics, rollback candidates, and safe-mode state.
4. In this PR, validate only index schema, typed IDs, paths rooted under the package store, and internal record consistency.
5. Keep all indexed package versions in an `.unvalidated` and unavailable state. Do not activate payloads or include them in registry snapshots.
6. Use a single package-store mutation coordinator with an interprocess lock or equivalent file coordination.
7. Use index generation or compare-and-swap semantics to prevent lost read-modify-write updates.
8. Use durable atomic replacement rules for index writes. Preserve the previous valid index after a failed write.
9. Reject package paths outside the package root and duplicate ID/version records with conflicting expected hashes.
10. Keep package records and payloads outside wiki storage and sync.

### Wiki-scoped storage

1. Add a new schema migration after the current schema version in `GRDBWikiStore`.
2. Add dedicated tables for renderer enablement and renderer preferences.
3. Use typed columns for package, version, registration, reference kind, and source identity.
4. Add uniqueness and check constraints. Add foreign keys where the wiki schema owns the referenced row.
5. Update `createFreshSchema(on:)` and the migration ladder together.
6. Add typed `WikiStore` methods for list, read, set, and remove operations.
7. Define one concrete discriminated event payload: `WikiStoreChangeEvent.resource(ResourceChangeEvent)` and `WikiStoreChangeEvent.rendererSettings(RendererSettingsChangeEvent)`. Do not create a parallel renderer event bus or another renderer event family.
8. Define closed, typed `RendererSettingsChangeEvent` payloads: `.machineInstallStateChanged(packageID: RendererPackageID, version: RendererPackageVersion)`, `.machineSafeModeChanged(isEnabled: Bool)`, `.wikiEnablementSet(packageID: RendererPackageID, isEnabled: Bool)`, `.sourcePreferenceSet(sourceID: SourceID, preference: RendererPreferenceReference)`, and `.sourcePreferenceRemoved(sourceID: SourceID)`. Payloads carry typed identities and new state only, never package or source bytes.
9. Define `PersistedWikiStoreChangeRecord` as a versioned `Codable` record with: `schemaVersion`, `eventID: UUID`, `sequence: UInt64`, `scope: WikiStoreChangeScope` where scope is exactly `.wiki(WikiID)` or `.machine(RendererMachineScopeID)`, `payload: WikiStoreChangeEvent`, and `committedAt: RFC3339Timestamp`. `RFC3339Timestamp` must encode an explicit numeric UTC offset such as `+00:00`; an offset-free date is invalid. The tuple `(scope, sequence)` is unique and monotonically increasing within that scope. `eventID` is globally unique and is used only for diagnostics and replay recognition; consumer correctness depends on per-lease cursors and idempotent authoritative handlers.
10. Inject `EventIDGenerating`, `EventSequenceGenerating`, `RendererEventProcessLeaseIDGenerating`, and `EventClock` dependencies. Production uses UUIDs, durable per-scope sequence allocation, a fresh process-lease UUID, and an offset-bearing wall clock; tests use deterministic identities, sequences, leases, and timestamps. Sequence allocation and event-record insertion are part of the same commit as the represented mutation, so rollback consumes neither a visible record nor a committed sequence.
11. Add a wiki renderer-event journal table, process-lease table, per-lease cursor table, and subsystem-checkpoint table in each wiki database. Persist every wiki-scoped `.rendererSettings` record in the same GRDB transaction as its enablement or preference write. The shared mutation seam commits the settings row, sequence allocation, and event record atomically; only after commit and lock release may the producer emit that payload once locally and post a wake-up.
12. Add a versioned machine renderer-event journal plus process leases, per-lease cursors, and subsystem checkpoints beneath the machine package store, separate from wiki databases and payload directories. Persist machine install-state and safe-mode records in the same package-store-coordinator critical section and durable atomic generation update as the machine index mutation. The package-store coordinator serializes sequence allocation, index/journal commit, lease/cursor/checkpoint updates, and compaction across processes. A failed coordinated mutation produces no committed machine record or producer emission.
13. Darwin notifications are wake-ups only. A wiki notification carries only the `WikiID`; a machine notification carries only `RendererMachineScopeID`. Darwin notification names or user-info never contain, encode, or stand in for `WikiStoreChangeEvent`, event UUID, sequence, or settings data. After a wake, each registered live process lease independently opens the durable journal for that scope and reads its unseen records; a wake with no unseen committed record is a no-op.
14. Define two-level consumer identity. `RendererEventSubsystemID` is stable for the logical consumer implementation, such as the renderer registry/model subsystem. Every live process instance creates a distinct `RendererEventProcessLeaseID`; cursor identity is exactly `(scope, RendererEventSubsystemID, RendererEventProcessLeaseID)`. Two live processes with the same subsystem ID therefore own separate durable cursors and each independently receives every applicable record. Distinct subsystems also own independent cursors and delivery streams.
15. Create each process lease with an injected UUID plus process identifier, executable identity, host identity where available, start timestamp, created timestamp, last-heartbeat timestamp, and status. Renew it on a named heartbeat interval shorter than a named bounded expiry. Clean shutdown marks the lease retired and records retirement time. A coordinator may reclaim only a lease whose heartbeat is older than expiry plus a bounded clock-skew safety margin. A new process always creates a new lease; it must never steal, overwrite, or reuse a still-live predecessor lease, even when subsystem and process metadata match.
16. Define restart bootstrap with a persisted per-`(scope, RendererEventSubsystemID)` checkpoint that records only a conservative sequence successfully incorporated into the subsystem’s authoritative state. A new lease first performs an authoritative settings or machine-index reload, snapshots the journal high-water mark in the same coordinated read, initializes its cursor to that high-water mark, and then reads later records. The subsystem checkpoint is advisory for diagnosing retention gaps and may lower the initial scan bound when retained history exists, but it never permits skipping the authoritative initial reload and never advances beyond a successfully handled sequence. This bootstrap cannot miss committed state because the authoritative reload covers all commits through the captured high-water mark and the new cursor consumes records after it.
17. Consumer delivery is **at least once**. On registration, wake, and reopen, each lease reads supported records with `sequence > durableCursor` in ascending sequence order. Reject an unsupported record schema version before handler invocation or cursor advancement. Invoke an idempotent handler that performs an authoritative reload of only the affected registry or preference projection; do not apply event payloads as non-idempotent deltas. Advance that lease’s durable cursor and conservative subsystem checkpoint atomically only after the handler returns successfully. A handler error leaves both unchanged. A crash after handler side effects but before cursor advancement causes documented replay on restart/recovery; `eventID` may identify the replay in diagnostics, but must not suppress the handler. The repeated authoritative reload must converge to the same final model state.
18. Define duplicate wake and replay behavior separately. Multiple wakes may cause repeated journal scans, but one in-flight ordered drain per lease prevents concurrent handling of the same sequence. A record already below that lease’s durable cursor is not handled again. A record at or above the cursor after a crash is handled again even if its `eventID` was previously observed transiently. Do not persist an event-ID dedup set as a substitute for cursor advancement or idempotent handlers.
19. Define cursor and subscription ownership explicitly: each process’s renderer subsystem owns one lease registration per open wiki scope and one machine-scope lease registration; bridge-level resource subsystems use their own stable subsystem IDs and separate leases. Opening an inactive wiki performs the authoritative reload/bootstrap before presenting renderer state. A wiki that remains inactive has no live lease and refreshes from authoritative wiki and machine state on next open, then consumes records after its captured high-water marks.
20. Use bounded retention with cursor, lease, checkpoint, and age rules. Keep records through a named minimum age and count floor. Every live lease cursor constrains compaction. Cleanly retired and expired leases continue blocking through a named bounded retirement/reclamation safety interval, then cease blocking; stale leases are reclaimed only under the coordinator after heartbeat expiry and safety margin. A subsystem checkpoint alone never blocks compaction. Compaction cannot remove a record still needed by any live or safety-retained lease. If any lease cursor or restart checkpoint predates the retained floor, detect the gap, perform an authoritative reload, atomically reset that lease cursor and conservative checkpoint to the captured high-water mark, and record a redacted diagnostic before normal ordered consumption resumes.
21. Subscription cancellation, model/wiki close, or owner deinitialization stops wake observation, cancels in-flight reads, releases continuations and store/model references, and cleanly retires the current process lease. It does not delete journal records or advance a cursor/checkpoint for a handler that did not return successfully. Process restart creates a replacement lease under the same subsystem ID, retains the predecessor record until retirement/expiry safety permits reclamation, and uses the authoritative bootstrap rather than reusing the predecessor cursor.
22. Update `WikiChangeBridge` explicitly: preserve its existing generic resource-wake behavior for resource notifications, but typed renderer wiki/machine wakes must route to the renderer journal reader. `WikiChangeBridge` must never synthesize `.resource` or any generic resource event from a renderer wake, and must never treat the Darwin notification as payload.
23. `WikiStoreModel` subscribes on the main actor through idempotent authoritative reload handlers. For `.resource`, preserve existing resource reload behavior. For wiki-enable or source-preference records, reload only the affected current-wiki registry/preference projection. Every machine install/safe-mode record fans out to all live `WikiStoreModel` and registry sessions across all open wikis in that process, refreshing only machine renderer availability and derived registry snapshots. Inactive wikis refresh machine availability from the authoritative machine index on next open; active renderer pins remain unchanged. At-least-once replay must leave the same final projection state.
24. `FileProviderFacade` and Tantivy subscribe/filter only `.resource`. They do not register renderer-journal leases and never receive machine or wiki renderer-setting events. Renderer events trigger no File Provider enumeration/projection write, Tantivy indexing, provenance activity, source version, or page version.
25. Implement model projections and mutators on `WikiStoreModel` under the main actor, and keep inactive preferences after disablement or package removal.
26. Add named identity, lease, and delivery tests: `RendererEventLeaseDeliveryTests.testTwoLiveProcessLeasesInSameSubsystemEachReceiveSameRecord`, `RendererEventLeaseDeliveryTests.testDistinctSubsystemConsumersEachReceiveApplicableRecord`, `RendererEventLeaseTests.testStillLiveLeaseCannotBeStolenOrReused`, `RendererEventLeaseTests.testRestartCreatesReplacementLeaseAndPerformsAuthoritativeReload`, `RendererEventLeaseTests.testCleanRetirementStopsDeliveryAndRetainsSafetyWindow`, `RendererEventLeaseTests.testStaleLeaseExpiresAfterHeartbeatAndSafetyMargin`, `RendererEventAtLeastOnceTests.testCrashAfterHandlerBeforeCursorCausesReplay`, `RendererEventAtLeastOnceTests.testReplayProducesIdempotentFinalModelState`, `RendererEventCursorTests.testCursorAdvancesOnlyAfterSuccessfulHandlerReturn`, and `RendererEventRetentionTests.testRetentionGapForcesAuthoritativeReloadAndCursorReset`, `RendererEventLeaseTests.testHeartbeatRenewalKeepsLeaseLiveAndBlocksReclamation`.
27. Retain named transport and isolation tests: `PersistedWikiStoreChangeRecordTests.testEnvelopePayloadRoundTrip`, `PersistedWikiStoreChangeRecordTests.testRejectsUnsupportedSchemaVersion`, `RendererEventWakeTests.testWakeWithoutCommittedRecordIsNoOp`, `RendererEventWakeTests.testDuplicateWakeRunsOneOrderedDrainPerLease`, `RendererEventCrossProcessTests.testTwoProcessesDeliverCommittedRecordsInSequenceOrder`, `RendererSettingsMutationEventTests.testTransactionRollbackPersistsAndEmitsNoEvent`, `RendererSettingsMutationEventTests.testSuccessfulCommitPersistsExactlyOneJournalRecordAndEmitsOnce`, `RendererMachineEventFanOutTests.testMachineEventRefreshesTwoLiveWikiSessions`, `RendererMachineEventFanOutTests.testInactiveWikiRefreshesOnNextOpen`, `RendererSettingsSubscriptionTests.testTeardownRetiresLeaseAndStopsWakeReads`, and `RendererSettingsProjectionIsolationTests.testCrossProcessRendererEventsNeverReachFileProviderOrTantivy`.
28. Preserve exactly-once only at the producer seam: `RendererSettingsMutationEventTests.testPostCommitProducerEmissionExactlyOnce` proves one local emission after a successful commit and none on throw, while `RendererSettingsMutationEventTests.testSuccessfulCommitPersistsExactlyOneJournalRecordAndEmitsOnce` covers both wiki and machine mutation seams and asserts exactly one committed sequence/record with expected scope, one local post-commit emission, and one wake. Consumer refresh tests assert at-least-once delivery and idempotent authoritative projection convergence. Retain `WikiStoreChangeEventRoutingTests.testResourceSubscribersNeverReceiveRendererSettings`, `WikiStoreChangeEventRoutingTests.testRendererSubscriberReceivesExactTypedPayloads`, deterministic generator/clock assertions, and an exhaustiveness test mapping every renderer mutator to its exact payload, scope, journal, and shared mutation seam.

Merge gate: fresh schema, upgrade, reopen, persisted-envelope round-trip and version rejection, transactional wiki and coordinated machine journals, Darwin wake-only behavior, two-level subsystem/process-lease identity, independent same-subsystem process delivery, ordered at-least-once handling, authoritative restart bootstrap, lease heartbeat/expiry/retirement/reclamation, cursor-after-success, documented crash replay with idempotent final projections, retention safety and gap reload, subscription teardown, machine fan-out, exactly-once producer emission, and File Provider/Tantivy/provenance/version isolation all pass under the phase-wide coverage and review policy.

## PR 4: Generic `SourceDetailView` presentation routing

Replace private format routing with the registry and planner.

1. Replace the complete `FileContentTab`, `availableTabs`, and presentation-body subsystem. Add `RendererPresentationState`, `RendererPresentationPlanner`, and `RendererHostView`.
2. Delete format predicates that exist only for presentation routing. Keep extraction, transcription, editor, and outline decisions in `SourceDetailView`.
3. Replace format switches in `contentArea`, `splitContent`, and `tabbedContent` with the generic renderer host and permanent Source presentation.
4. Move PDF, HTML, Mermaid, and media view construction into built-in factories.
5. Adapt PDF quote anchors, HTML-without-markdown behavior, Mermaid standalone versus fenced content, media transcript state, editor state, and outline inputs through typed planner or host inputs.
5. Resolve a logical or exact stored preference when the source changes.
6. Pin one exact `RendererReference` for the lifetime of the rendered pane.
7. Do not replace the pinned renderer when the registry changes. Apply changes only after the pane closes or the user selects a new renderer.
8. Preserve the selected presentation per source.
9. Show the selector only when at least one renderer is available.
10. If resolution or rendering fails, select Source and show a short reason without hiding source content.
11. Route detailed, redacted diagnostics through `DebugLog`.
12. Keep renderer controls inside the rendered pane.
13. Add keyboard shortcuts and VoiceOver labels for Source, Rendered, and Split.
14. Ensure split layout preserves a usable source pane at the minimum detail width.
15. Add `SourceDetailRendererArchitectureAuditTests.testNoFormatSpecificRendererRouting`. Use Swift syntax inspection or a strict source allow/deny list. Reject legacy presentation symbols and renderer-only format predicates, including `FileContentTab`, `availableTabs`, `pdfOnlyContent`, `tabbedContent`, renderer-only `splitContent`, `isPDF`, `isHTMLSource`, `isMermaidSource`, media renderer predicates, package IDs, Excalidraw, and JSON Canvas. Permit format checks only for extraction, transcription, editor, or outline behavior.

Merge gate: all existing source presentations behave as before through the registry, and fallback tests pass.

## PR 5: Static package validation and isolated WebView sessions

Build the installed renderer security boundary.

### Package installation and validation

1. Define package format v1 as a **local directory only** with one normalized JSON manifest and declared static assets. Archives, archive extraction, compressed-size accounting, and remote package sources are out of scope.
2. Implement one `RendererPackageValidator` as the only authority that can produce a validated package record.
3. Copy the candidate directory into a newly created staging directory inside the App Group container without following links. Validate only the staged copy so the source cannot change underneath validation.
4. Reject absolute paths, `..`, symlinks, hard links, device files, sockets/FIFOs, mount or filesystem-boundary escapes, duplicate normalized or case-fold-colliding paths where applicable, unsupported file types, excess files, excess copied bytes, excess decoded input size, and files that change identity or metadata during copy/validation.
5. Verify every declared asset hash before activation.
6. Reject undeclared and missing files.
7. Verify the package hash after staging and before index activation.
8. Move a validated immutable version into its final directory atomically.
9. Clean up staging directories after every success, validation failure, cancellation, timeout, process-recovery scan, and failed atomic activation. Cleanup failure must be diagnosed and must never activate the package.
10. Fail closed on every validation, filesystem-race, cleanup, or hash error.
11. Add adversarial real-filesystem fixtures for traversal, absolute paths, symlinks, hard links, special files, duplicate/case-colliding names, source mutation during copy, replacement races, permission failures, undeclared/missing files, over-limit trees, interrupted staging, stale staging recovery, and cleanup after cancellation/failure. Name this suite `RendererDirectoryValidationTests`; remove the superseded archive-oriented suite name.

### WebView session

1. **WV-01 — Session state:** Add `WikiAppWebViewSession` as a main-actor-owned finite state machine. Model idle, loading, ready, failed, and closed states as one enum.
2. **WV-02 — Limits:** Add a named policy for concurrent WebViews, source byte limits, decoded limits, bridge message limits, and load timeout.
3. **WV-03 — Package scheme:** Use a custom package URL scheme and `WKURLSchemeHandler` for the entry document and every package asset.
4. **WV-04 — Pre-parse CSP:** Make the scheme handler synthesize the entry response with CSP response headers before WebKit parses package content. Never use `loadHTMLString` or a file or network base URL.
5. **WV-05 — Ephemeral storage:** Create a fresh nonpersistent data store for each session.
6. **WV-06 — Isolated host world:** Install the native handler and all host-owned bridge and gesture-verification code only in a named isolated `WKContentWorld`. Add an isolated broker that communicates with page code through a narrow `window.postMessage` envelope; package page code cannot replace or invoke host-owned gesture state directly.
7. **WV-07 — Bridge authorization:** Require a per-session capability token, exact source-window and main-frame checks, unique request IDs, a closed method enum, payload limits, replay rejection, and cancellation on close.
8. **WV-08 — Resource policy:** Use CSP to allow package-scheme resources only and block subresource network APIs, objects, workers, forms, framing, base changes, and navigation.
9. **WV-09 — Typed input:** Expose typed `input.read` for one authorized source or artifact version. Return bounded bytes and declared metadata only.
10. **WV-10 — Declared links:** Permit typed link requests only when the descriptor declares link support.
11. **WV-11 — Trusted activation:** Verify external-link activation with host-owned isolated-world code that observes trusted capture-phase pointer or keyboard activation. Require `event.isTrusted`, the exact live main window, and the exact main frame. On a qualifying activation, mint a cryptographically unpredictable, one-use, short-lived nonce bound to the session identity and a host-normalized destination.
12. **WV-12 — Nonce redemption:** Require the link request to redeem that nonce for the identical normalized destination before expiry. Reject absent, expired, replayed, substituted, redirected, cross-frame, cross-window, or post-close redemption. Invalidate pending nonces on destination change, navigation, frame/window mismatch, session failure, and close. A redirect target requires a new verified activation and nonce; never carry authorization across redirects.
13. **WV-13 — Untrusted page claims:** Treat page-provided booleans, timestamps, event descriptions, or synthetic DOM events as untrusted data and never as proof of user activation. Open an external URL through `NSWorkspace` only after successful host-side nonce redemption.
14. **WV-14 — Navigation cancellation:** Use the navigation delegate to cancel disallowed top-level and frame navigation, redirects, forms, links, and `window.open`. Do not treat it as a subresource interceptor.
15. **WV-15 — Teardown:** Stop loading and remove all message handlers, delegates, scheme tasks, and references during close and deinitialization.
16. **WV-16 — Diagnostics:** Add deterministic diagnostics without source content, credentials, or package asset contents.
17. **WV-17 — Failure taxonomy:** Add `RendererSessionFailureKind`. Count load timeout, entry navigation failure, bridge bootstrap failure, and `webViewWebContentProcessDidTerminate` for the same package version. Do not count source validation, size rejection, user close, or host cancellation.
18. **WV-18 — Failure window:** Use a named threshold of three counted failures within ten minutes. Prune entries with an injected clock. A successful ready session does not erase earlier failures and normal aging removes them. Serialize updates through the package-store coordinator.
19. **WV-19 — Safe mode:** Safe mode disables installed renderers for the current machine until the user resets it. Built-in renderers and Source remain available.
    The machine index schema v3 stores only package ID, version, a closed failure cause, and a timestamp. It stores no content, URL, credential, byte payload, token, nonce, cookie, or storage value. The v2 migration is data-preserving for validated descriptors, safe mode, and generation. It uses a SQLite savepoint with derived-index replacement. If that replacement fails, the migration rolls back and leaves v2 authoritative.
20. **WV-20 — Activation validation:** Revalidate every indexed version through `RendererPackageValidator` before activation. Only validator-produced `.validated` records can enter registry snapshots.
21. **WV-21 — Immutable resource root:** Resolve scheme resources beneath the validated immutable version root without following links. Reject replacement of an existing ID/version by a different hash.
22. **WV-22 — Main-actor UI boundary:** Keep WebKit delegate callbacks and SwiftUI state changes on the main actor. Do not write SwiftUI state synchronously from `makeNSView` or `updateNSView`.

### Required test infrastructure

1. Add a shared hosted WebKit harness based on `ChatTranscriptHostedTests` and `PageDetailViewHostedTests`.
2. Add injected navigation-policy, package-resource, clock, package-filesystem, and data-store seams.
3. Add explicit teardown observations for handlers, delegates, loads, and scheme tasks.
4. Start real loopback HTTP and WebSocket servers on OS-assigned ephemeral ports for hosted isolation tests. Give every test a unique unpredictable observation token and record requests and connection attempts by token. Do not substitute `URLProtocol` or any in-process/mock interception layer for this boundary test.
5. Before every negative isolation matrix, run a permissive positive-control WebView/configuration that is intentionally allowed to contact both live servers and assert that each server observes its unique token. Fail the test as inconclusive if either positive control cannot observe traffic; a silent or unavailable receiver must never produce a passing isolation claim.
6. Run the renderer session’s negative hostile matrix against those same live servers and fail if either server observes the renderer token. Cover redirects, fetch, XHR, WebSocket, EventSource, CSS `url()` and `@import`, images, media, fonts, iframes, workers, service workers, forms, `window.open`, dynamic script insertion, and navigation. Keep cookies, local storage, and file URL attempts in the storage/file isolation matrix.
7. Add `RendererContentWorldBridgeHostedTests` for wrong tokens, wrong windows or frames, replayed IDs, unknown methods, excess payloads, iframe requests, and responses after close.
8. Add `RendererTrustedActivationHostedTests` with real pointer and keyboard positive controls plus hostile cases for synthetic/untrusted events, page booleans/timestamps, wrong main frame/window, absent/expired/replayed nonces, destination normalization and substitution, redirects, cross-frame redemption, navigation invalidation, and redemption after close. Assert one-use behavior and that rejected cases never invoke `NSWorkspace`.
9. Add fake-clock and concurrent-store tests for failure-window boundaries, non-counting failures, process termination, persistence after reopen, built-in immunity, and safe-mode reset.
10. Add two-store race tests for install, removal, failure accounting, and safe-mode reset. Assert that generation checks prevent lost updates.

Merge gate: package validation, bridge, network isolation, storage isolation, teardown, limits, fallback, and safe-mode tests pass.

## PR 6: Excalidraw and JSON Canvas validation renderers

Implement both format cases through the shared contract.

### Excalidraw installed package

1. Add MIME, extension, and bounded JSON signature matchers for `.excalidraw`.
2. Vendor and record one reviewed Excalidraw viewer bundle and license.
3. Package the viewer as a static renderer package with pinned manifest, assets, and package hashes.
4. Render in read-only mode with pan and zoom.
5. Respect light and dark appearance and Reduce Motion.
6. Route external link requests through the typed host request and user-gesture gate.
7. Provide raw JSON in Source and preserve it after every package failure or removal.
8. Keep all Excalidraw code and registration outside `SourceDetailView`.

### JSON Canvas built-in renderer

1. Add MIME, extension, and bounded JSON signature matchers for `.canvas`.
2. Decode nodes, edges, positions, colors, labels, file links, and wiki links into typed values.
3. Reject invalid and excessive documents with clear fallback diagnostics.
4. Implement a native SwiftUI canvas with pan, zoom, selection, keyboard traversal, and outline navigation.
5. Resolve file and wiki links through typed host actions.
6. Use system fonts, semantic text styles, system colors, and named layout metrics.
7. Support VoiceOver labels, focus order, light and dark appearance, and Reduce Motion.
8. Keep all JSON Canvas code and registration outside `SourceDetailView`.

### Golden validation

1. Add deterministic Excalidraw fixtures for basic shapes, text, arrows, embedded assets, links, and malformed data.
2. Add deterministic JSON Canvas fixtures for nodes, edges, links, selection, outline, and malformed data.
3. Add semantic output goldens and hosted appearance snapshots where stable.
4. Add pan, zoom, keyboard, VoiceOver, link, isolation, and fallback scenarios.

Merge gate: issue #593 and #594 validation suites pass through the same registry contract.

## PR 7: Package management, diagnostics, rollback, removal, and final integration

Add native settings UI and complete the user workflow.

1. Add a Renderers settings tab through `WikiFSApp.Settings` and `SettingsTab`.
2. Show two clearly labeled scopes:
   - Installed on This Mac
   - Enabled for This Wiki
3. Add local package installation with a directory-only `NSOpenPanel`: set `canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`, and reject any non-directory URL again at the installation boundary. Files and archives cannot be selected or installed. Label the control and help text “Install Renderer Directory” and state: “Package format v1 accepts one local directory. Files and archives are not supported.” Add `RendererSettingsPackagePickerTests.testV1PickerAcceptsOneDirectoryAndRejectsFilesAndArchives` to assert panel configuration, single selection, boundary rejection, and the explicit v1 message.
4. Show package name, exact version, registrations, compatibility, hash status, install state, and last diagnostic.
5. Add enable and disable controls for the current wiki.
6. Add renderer preference controls only where multiple compatible renderers exist.
7. Add version selection and rollback to another validated installed version.
8. Add removal with confirmation. Explain that source data stays available and the preference remains inactive.
9. Add safe-mode status and a reset action.
10. Use progressive disclosure for detailed diagnostics.
11. Keep primary actions keyboard accessible and VoiceOver labeled.
12. Use system typography and semantic colors. Do not add custom font sizes when a semantic SwiftUI text style fits.
13. Refresh registry snapshots after install, enablement, rollback, removal, and safe-mode reset.
14. Do not replace an active session pin during registry refresh.
15. Add end-to-end tests from installation through rendering, fallback, rollback, removal, reinstall, and restored logical preference.
16. Confirm that PR 1’s retained scoped mutation report still applies to the exact audited ancestry; rerun only if later PRs changed the covered pure matcher, priority, digest, canonical-envelope, or preference-resolution logic.
17. Run `make build`, `make test`, the opted-in app test command required by `Package.swift`, and bare `swift build` and `swift test` after prerequisite sync.
18. Open the final integration PR. Do not merge it; only the operator may merge.

Merge gate: all issue #1026 exit criteria, per-PR test inventories, exact-head checks, retained audit/review records, and final commands pass; no critical or high finding is unresolved; every medium or low finding is fixed or explicitly rebutted; and any specialist review required after a critical/high fix has passed.

### Phase 8 recovery amendment for issue #1026

The approved Phase 8 recovery supersedes the Phase 7 package-management wording
above where the retained implementation resolves the design detail differently:

1. Compatible validated renderer packages are machine-scoped and available to
   every wiki. Persisted per-wiki enablement rows and APIs remain only as
   compatibility data; Phase 8 does not expose enablement controls.
2. The advanced import action is labeled “Import Renderer Package…” and accepts
   one local directory only. The existing validator and coordinated machine
   store remain the import and storage boundary.
3. The reviewed bundled Excalidraw package is bootstrapped from the signed app
   resources through the existing validator and machine store. Source and
   native renderer fallback remains available on every failure path.
4. The repository maintainer skill remains repository documentation. Runtime
   WIKI_STATE receives only the bounded chat reference; no generic chat skill
   execution or system-prompt injection is added.
5. Delivery is the Phase 7 integrated main plus this single Phase 8 recovery PR;
   the earlier seven-PR delivery wording is superseded for this recovery.

# Acceptance Criteria

- **AC.1:** Portable renderer IDs prevent package, version, registration, exact-reference, and logical-reference namespace interchange at compile time.
- **AC.2:** Built-in and installed renderers use one `RendererDescriptor` and `RendererRegistrySnapshot` contract.
- **AC.3:** Registry selection uses MIME, extension fallback, bounded sniffing, and typed artifact matchers without installation-order dependence.
- **AC.4:** Logical preference resolution and exact preference resolution use documented compatibility and stable tie-break rules.
- **AC.5:** An active rendered pane pins one exact `RendererReference` until the pane closes or the user explicitly changes it.
- **AC.6:** `SourceDetailView` contains no renderer-format or installed-package presentation routing. PDF, HTML, Mermaid, media, Excalidraw, and JSON Canvas selection and construction occur only through the planner, registry, host, and renderer factories.
- **AC.7:** Existing PDF, HTML, Mermaid, and media presentations retain their characterized behavior through built-in registry adapters.
- **AC.8:** Source, Rendered, and Split appear only in valid combinations and preserve the selected presentation per source.
- **AC.9:** Source remains readable when no renderer matches or when a renderer is missing, disabled, incompatible, oversized, corrupt, or failed.
- **AC.10:** Package validation rejects traversal, links, duplicates, undeclared files, missing files, unsupported files, excess limits, and all hash mismatches.
- **AC.11:** Package and asset hashes use one deterministic, versioned canonical format.
- **AC.12:** Installed package payloads and records are machine-scoped and do not enter wiki storage or File Provider projections.
- **AC.13:** Wiki enablement and source preferences survive database reopen and schema upgrade without storing package payloads.
- **AC.14:** Installed WebView renderers cannot make direct network requests, follow network redirects, read arbitrary files, use durable browser storage, or invoke undeclared bridge methods.
- **AC.15:** Each renderer session uses one authorized source or artifact version and enforces declared input and decoded-size limits.
- **AC.16:** Session close removes all message handlers, delegates, pending scheme tasks, loads, and transient references.
- **AC.17:** External URLs open only through a host action after a verified user gesture.
- **AC.18:** Repeated installed-renderer failures activate safe mode while Source and built-in renderers remain available.
- **AC.19:** Excalidraw works as an installed static WebView renderer with read-only pan and zoom, isolation, and Source fallback.
- **AC.20:** JSON Canvas works as a built-in native renderer with typed decoding, pan, zoom, selection, outline navigation, typed links, and Source fallback.
- **AC.21:** Source, Rendered, Split, Excalidraw, JSON Canvas, and settings controls support keyboard navigation and VoiceOver without a keyboard trap.
- **AC.22:** Renderers and management UI support light appearance, dark appearance, and Reduce Motion.
- **AC.23:** Package installation, per-wiki enablement, diagnostics, rollback, removal, safe-mode reset, and reinstall workflows work without source loss.
- **AC.24:** Rendering creates no provenance activity, source version, or page version.
- **AC.25:** `make build`, `make test`, required opted-in app tests, bare `swift build`, and bare `swift test` pass from the documented SwiftPM workflow.
- **AC.26:** The orchestrator delivers the implementation as the seven dependency-ordered PRs above, and each PR has passing tests and an implementation review before handoff.

# Test Strategy

Use Swift Testing for new unit and integration tests. Use serialized, main-actor hosted suites for live AppKit and WebKit tests. Use bounded confirmations or explicit waiters instead of sleeps.

| Acceptance criterion | Required regression test |
| --- | --- |
| AC.1 | `RendererIdentifierBoundaryTypecheckTests` |
| AC.2 | `RendererDescriptorContractTests.testBuiltInAndInstalledShareContract` |
| AC.3 | `RendererRegistryTests.testAllMatchersAndInstallationOrderPermutation` |
| AC.4 | `RendererPreferenceTests.testLogicalAndExactStableResolution` |
| AC.5 | `RendererSessionPinningTests.testRegistryRefreshDoesNotReplaceActivePin` |
| AC.6 | `SourceDetailRendererArchitectureAuditTests.testNoFormatSpecificRendererRouting` |
| AC.7 | `BuiltInRendererCharacterizationTests` golden scenarios |
| AC.8 | `RendererPresentationPlannerTests.testValidSourceRenderedSplitCombinationsAndPersistence` |
| AC.9 | `RendererFallbackTests.testAllFallbackReasonsKeepSourceVisible` |
| AC.10 | `RendererDescriptorValidationTests` and `RendererDirectoryValidationTests` adversarial invalid-directory and staging-cleanup matrix |
| AC.11 | `RendererSHA256Tests.testDigestBytes`, `RendererDigestHexCodecTests.testCanonicalLowercaseHex`, `RendererDigestHexCodecTests.testRejectsMalformedDigests`, `RendererPortableHashImportTests.testSupportedPlatformImports`, and `RendererPackageHashTests.testCanonicalEnvelopeGoldenDigestAndOrderIndependence` |
| AC.12 | `RendererPackageScopeTests.testPayloadOutsideWikiAndProjection` |
| AC.13 | `RendererSchemaMigrationTests`, `PersistedWikiStoreChangeRecordTests`, `RendererEventLeaseDeliveryTests`, `RendererEventLeaseTests.testHeartbeatRenewalKeepsLeaseLiveAndBlocksReclamation` (plus the remaining `RendererEventLeaseTests` cases), `RendererEventAtLeastOnceTests`, `RendererEventCursorTests`, `RendererEventRetentionTests`, `RendererEventWakeTests`, `RendererEventCrossProcessTests`, `RendererSettingsMutationEventTests.testSuccessfulCommitPersistsExactlyOneJournalRecordAndEmitsOnce` (plus the remaining `RendererSettingsMutationEventTests` cases), `RendererMachineEventFanOutTests`, `RendererSettingsSubscriptionTests`, and `RendererSettingsProjectionIsolationTests` cover versioned persistence, two-level lease identity, independent process delivery, at-least-once replay, cursor-after-success, restart bootstrap, lease lifecycle including heartbeat renewal preventing reclamation until expiry plus skew/safety bounds, retention/gap recovery, one post-commit producer emission per successful commit, exactly one committed sequence/record with expected wiki and machine scope plus one local emission and one wake, machine fan-out, teardown, and subscriber isolation |
| AC.14 | `RendererNetworkIsolationTests` and `RendererSessionIsolationTests` hostile fixture matrix using live loopback HTTP/WebSocket servers with mandatory positive controls |
| AC.15 | `WikiAppWebViewBridgeTests.testAuthorizedInputAndLimits` |
| AC.16 | `WikiAppWebViewBridgeTests.testCloseRemovesHandlersDelegatesLoadsAndTasks` |
| AC.17 | `RendererTrustedActivationHostedTests` trusted pointer/keyboard controls plus nonce expiry, replay, substitution, redirect, frame/window, and close rejection matrix |
| AC.18 | `RendererSafeModeTests.testThresholdDisablesInstalledOnlyAndResetRestores` |
| AC.19 | `ExcalidrawRendererGoldenTests` and `ExcalidrawIsolationHostedTests` |
| AC.20 | `JSONCanvasRendererGoldenTests` and `JSONCanvasInteractionHostedTests` |
| AC.21 | `RendererNativeAccessibilityTreeHostedTests`, `RendererKeyboardTraversalHostedTests`, `RendererWebFocusTraversalHostedTests`, and `RendererKeyboardShortcutTests` |
| AC.22 | `RendererAppearanceHostedTests.testLightDarkAndReduceMotion` |
| AC.23 | `RendererPackageLifecycleIntegrationTests.testInstallEnableRollbackRemoveReinstall` |
| AC.24 | `RendererReadOnlyPersistenceTests.testSessionsCreateNoWikiVersionOrActivityRows` |
| AC.25 | `swift run DynamicRendererPRSeriesAudit build-suite --head <exact-head-sha> --evidence tmp/dynamic-renderer-gates` executes and records the concrete `DynamicRendererBuildAndSuiteGate`; focused command-runner, failure, head-race, and schema tests live in `Tests/DynamicRendererPRSeriesAuditTests/` |
| AC.26 | `swift run DynamicRendererPRSeriesAudit verify --series plans/dynamic-renderers-pr-series.json --evidence tmp/dynamic-renderer-gates` checks branch ancestry, PR order, exact-head checks/reviews, and schema-valid SHA-keyed records; focused stale/wrong/racing tests live in `Tests/DynamicRendererPRSeriesAuditTests/` |

Add the missing hosted WebKit isolation infrastructure in PR 5. Network tests must use real loopback HTTP and WebSocket servers on ephemeral ports, unique per-test tokens, mandatory permissive positive controls, and the negative hostile matrix. Fail if a renderer request reaches either receiver, and fail as inconclusive if either positive control cannot prove the receiver works. `URLProtocol` and custom-protocol substitutes are not acceptable. The storage test must create two separate sessions and prove that cookies and local storage do not cross the boundary.

For every PR, retain the machine-readable production-symbol and branch-to-test inventory beside its exact-head audit record. Map every changed production symbol and every decision/error path to named tests. Require success and error cases plus boundary, cancellation, and teardown cases wherever the symbol can encounter them. A testing reviewer must reject any unmapped path; passing aggregate coverage percentages do not waive this gate.

Use deterministic fixtures. Remove timestamps, random IDs, animation state, and nondeterministic font assumptions from goldens. Prefer semantic rendering assertions when pixel snapshots would be unstable.

For AC.21, assert native accessibility roles, labels, actions, and focus order. Drive deterministic Tab and Shift-Tab traversal through native hosts, WebView content, and the host exit path. Test keyboard shortcuts separately. Also document a manual VoiceOver matrix for Source, Rendered, Split, Excalidraw, JSON Canvas outline, renderer settings, and exiting the WebView. Hosted tests cannot verify spoken VoiceOver output, so treat the manual matrix as a release gate rather than an automated claim.

Run targeted tests in each PR. Run the full suite before each PR opens. After every push, rerun the exact-head audit and invalidate earlier check/review evidence. Open no dependent PR until the predecessor’s exact head passes its test inventory, required checks, and review gate. The final gate must include:

```text
make build
make test
WIKIFS_APP_TESTS=1 swift test
make prompts
swift build
swift test
```

Use the repository’s exact opted-in app-test command if its documented command differs when execution starts.

# Review Strategy

Run a plan review before handoff. Retain the findings and dispositions. No phase or final gate may pass with an unresolved critical or high finding. Fix or explicitly rebut every medium and low finding. After a critical or high fix, rerun the relevant specialist review against the new exact head.

For implementation, the `dynamic-renderers-orchestrator` must assign review by risk:

- Use a security-focused reviewer for PR 1 hash contracts and PR 5 package/WebView isolation.
- Use a Swift concurrency reviewer for the session finite state machine, WebKit callbacks, teardown, and limits.
- Use a SwiftUI and macOS design reviewer for PR 4, PR 6, and PR 7.
- Use a testing reviewer for hosted WebKit, accessibility, appearance, and golden suites.
- Use a general implementation reviewer for every PR after tests pass.

For every PR, Sol reviews the clean checkout of the same exact head SHA that the tests and checks cover. Retain findings and dispositions keyed by that SHA. No phase or final gate passes with an unresolved critical or high finding. Fix or explicitly rebut every medium and low finding. If a critical or high finding is fixed, rerun the relevant specialist review and the general implementation review against the new exact head before opening a dependent PR.

Before the final PR opens, run one cross-series exact-head audit. Confirm that no format branch moved back into `SourceDetailView`, no network path bypasses the package scheme, no package bytes entered wiki storage, and no renderer action creates provenance. Bind the result to local SHA, `headRefOid`, check-run SHAs, approval/review commit SHA, `baseRefName`, and `baseRefOid`; rerun after any push.

# Documentation Strategy

Update documentation with STE-flavored prose.

1. Update `plans/dynamic-renderers.md` when implementation resolves a design detail differently. Keep the issue contract and final security model current.
2. Add one detailed implementation document under `plans/` for package format, canonical hashing, WebView isolation, persistence schema, and safe mode.
3. Add progress records under `progress/` after each design-relevant PR.
4. Update `PLAN.md` as the index to the dynamic-renderer plan and implementation document.
5. Do not add bug-fix-only entries to `PLAN.md` or `PROGRESS.md`.
6. Add user-facing help for renderer installation, enablement scope, fallback reasons, rollback, removal, and safe-mode reset.
7. Record the Excalidraw bundle version, source, license, reviewed hash, and update procedure.
8. Document the local-only trust model. State that signing and distribution remain out of scope.
9. Document test commands and hosted WebKit isolation fixtures.

# Risks, Blockers, and Required Decisions

- **Merged design baseline:** PR #1006 is merged. The orchestrator must start from updated `main` that contains merge commit `75f5b7cd` or its descendant.
- **WebKit network enforcement:** CSP alone is not sufficient. The implementation must use a package-only resource scheme, CSP response headers before parsing, navigation cancellation for navigations, and live hostile tests for every listed subresource channel. `WKNavigationDelegate` is not a general subresource interceptor. If any tested channel reaches the receiver, stop PR 5 and request a security decision.
- **Package format:** Use the local static manifest-and-assets format in this plan. Do not add remote distribution, signing, dependency managers, or executable backends.
- **Preference storage:** Use dedicated wiki tables. Do not store renderer preferences as untyped metadata JSON.
- **Safe mode:** Use the named threshold in PR 5 unless testing proves it creates false activation. Any user-visible threshold change needs operator approval.
- **Existing HTML WebView:** It permits external resource loads. Keep it separate from installed renderer sessions.
- **Test stability:** Hosted WebKit and appearance tests can wedge when run in parallel. Serialize them and use the existing hosted-test gates.
- **Swift version guidance:** Skills can target newer Swift and macOS versions. The implementation must follow the repository toolchain and SwiftPM constraints.
- **Branch policy:** Never commit or push to `main`. Open PRs and leave merge decisions to the operator.
- **Scope control:** Do not absorb worker runtime, extraction, credentials, editable rendering, signing, or distribution work into this series.

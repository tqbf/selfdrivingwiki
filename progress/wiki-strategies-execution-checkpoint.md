---
timestamp: 2026-10-03T010000Z
title: Wiki strategies execution checkpoint
branch: feature/wiki-strategies-cumulative-ingestion
status: active
---

# Wiki strategies execution checkpoint

The approved goal remains active. The implementation is not release-ready.

## Progress

Committed work:

- `ad13a8c5`: strategy persistence, atomic writes, captured host context, and mounted projection.
- `74a75e3f`: synchronized cumulative prompts and scripted pipeline contracts.
- `fbff82aa`: isolated live evaluator, source-identity checks, budgets, reports, and negative controls.
- `bfacccb6`: descriptor cleanup and shared process-registry test isolation.

The operator approved `zai/glm-5.3` for execution. Recent bounded delegates use that exact model.
This approval does not waive independent-review diversity.

## Verification

Persistence, atomicity, scripted pipeline, capture, projection, renderer, and evaluator targeted suites passed.
Pre-commit lint passed with zero violations after 17 initial findings were corrected.
`make build` and `make test` passed. Bare `swift build` passed.
The full bare test run after narrow descriptor and test-isolation fixes passed.
A later handoff `make build` passed, but `make test` failed two tests during a confirmed 905-second thermal system sleep.
Production wall-clock timeout semantics remain unchanged. The proposed awake-time changes were reverted.
Final `caffeinate -i make test` and `caffeinate -i swift test` each passed 4,343 tests across 450 suites.
The sweep-gate mechanics self-test now uses an isolated instance. Commit: `c3badb43`.
The earlier guarded-descriptor crash cause remains unproven. A clean run does not establish causality.

The hosted editor now passes five of six scenarios, with real controls and events:
Save/Cancel/Reset, draft-protected switching, conflict-preserving reload, no page writes on save, and light/dark appearances.
Destructive confirmations use their registered Return shortcut after text-editor focus release.
Synthetic mouse events activate ordinary buttons but not destructive buttons on this host.

The template-menu scenario remains incomplete. A child-process experiment added 771 lines but wedged inside `NSApp.run()`.
The parent timeout killed the child and preserved a full six-test summary. That is a failure, not successful isolation evidence.
`general-purpose:glm-ui-cleanup` removes the failed child approach and restores the concise explicit template blocker.
Do not add a skip or expected issue to hide this required workflow.

A 2026-10-04 in-repo investigation (`tmp/f2-template-menu-investigation.md`, scratch probe `tmp/probepicker/`) sharpened the blocker into a host capability boundary.
In a plain executable host the full supported menu workflow runs: `Picker` + the app's `.menuStyle(.borderlessButton)` idiom bridges to a real `SwiftUIPopupButton` whose `NSMenu` is eagerly populated with the prompt row plus the six templates, every item carries SwiftUI's real `PickerOptionTarget` (`menuAction:`), and `NSMenu.performActionForItem(at:)` dispatches the selection synchronously — no tracking session, no events.
In the `swift test` CLI host the same views never mount that bridge (SwiftUI-native ring-only rendering), and the one variant that does mount (`Menu` + borderlessButton) keeps its menu empty outside a tracking session (`menuNeedsUpdate`, `NSMenu.update()`, `itemTitles` all empty), which this host cannot survive.
Run-loop pumping, activation state, ActivityWindow-style mounts, async-runtime driving, and interop presence were each tried and falsified in-run.

A same-day dedicated-executable-host attempt (public init seam on `WikiStrategyEditorView`, a `WikiStrategyEditorMenuHelper` target following the `ProviderConfigMutationHelper` pattern, a bounded terminate-on-deadline subprocess wait in the suite) compiled the helper against the WikiFS module but SwiftPM linked no WikiFS objects into the dependent executable (`Undefined symbols: WikiStrategyEditorView.init/metadata` from `main.o`; the unconditional dependency behaves the same; the WikiFSAppTests test target links fine because test targets receive executable-dependency objects).
The house remedy is the wikictl/WikiCtlCore split — moving the editor UI into a library target — which is a production-target redesign beyond this fix's scope; the attempt was reverted whole (no code churn remains).
Remaining routes: that library split, or the operator recording the manual template-menu verification as the AC.4 acceptance evidence.

### Live evidence

Artifacts remain under project-local `tmp/wiki-strategy-eval/`.
Character history passed structural checks in the `2026-10-02T235350Z` run.
Documentation strategies passed in the `2026-10-03T002006Z` run.
Repository history passed identity, history, citations, and provenance in the latter run.
Its superseded check failed on historical subsections. The evaluator correction has positive and negative regression tests.
The original live reports remain unchanged. No later repository live report or human rubric decision exists.
The first live run exposed missing supporting provenance. The prompt clarification improved later observed provenance.
This is evidence from these fixtures, not a guarantee of model obedience.

## Remaining work

UI cleanup and documentation are committed as `b6b9d917` and `1344300f`.
The final keyboard and supported accessibility picker probes were inert. Their patches were removed.
The committed hosted suite preserves five passes and one explicit template-menu failure.
A read-only adversarial completion check confirmed the remaining external gates.

1. Obtain an eligible independent review family or an explicit operator waiver.
2. Obtain human rubric decisions.
3. Provide a supported real-menu host or perform and record manual production template workflow checks.
4. Push and prepare a PR after the required gates are resolved. Keep any earlier draft explicitly incomplete.

The operator was unavailable when asked to choose these paths. The goal is blocked, not complete.

The review-family question remains unanswered because the operator was unavailable.
Both OpenAI and GLM authored code. Do not call a GLM review independent for GLM-authored portions.
The operator owns merge and queue decisions. No automatic merge, queue action, or issue-state change is authorized.

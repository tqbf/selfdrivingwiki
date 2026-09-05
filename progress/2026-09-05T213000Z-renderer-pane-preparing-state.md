---
timestamp: 2026-09-05T213000Z
title: Renderer panes hold while their session prepares
branch: bugfix/renderer-pane-preparing-state
status: complete
---

# Renderer panes hold while their session prepares

## Progress

Clicking the renderer tab of an installed web-package renderer in the source
detail view bounced straight back to Source. The log showed only
`SourceDetailView: renderer fallback ... The selected renderer could not be
loaded.` retries. No preparation attempt ever failed, because no preparation
ever finished.

The root cause was a race between the fallback and the async session
preparation. Built-in renderers (PDF, HTML, media) return a view
synchronously, so the pane could show them at once. Installed packages need
`RendererSessionPreparationOwner` to build a session first. The body ran
before preparation finished, `renderedContent` returned nil, and the host
fell back. The fallback reverted the selection to Source and cleared the pin.
The revert changed `rendererPreparationKey`, so `.task(id:)` re-ran and its
guard saw the Source selection and cancelled the in-flight preparation. Every
retry repeated the cycle, so the tab was unreachable.

The fix gives the owner an observable phase:
`idle`, `preparing`, `prepared`, `failed`. `cancel()` returns to `idle`.
A new `markUnavailable()` records a definitive failure for a pane whose
request assembly cannot succeed. `renderedContent` now returns a
`RendererPreparingPane` while the phase is `idle` or `preparing` and returns
nil only on `failed` or a session failure after mount. The host no longer
reverts during the in-flight window, so preparation completes and the real
pane mounts. `RendererActivationView` ("Open in Window") uses the same pane
instead of flashing a false "could not be presented" error during
preparation.

`prepareSelectedRendererSession` now splits its guard. A missing selection
cancels quietly. A selected pane that cannot be prepared (no package
configuration, no authorized input) calls `markUnavailable`, so the host
falls back with a truthful reason instead of waiting forever.

Tests: `RendererSessionPreparationOwnerPhaseTests` covers the phase
transitions, the cancel-during-preparation staleness gate, authority closure
on cancel and on `markUnavailable`, and a newer request superseding a stale
failure. `SourceDetailRendererArchitectureAuditTests` gained a structural
contract for the pane-holding rule. The audit file also carries one stale
assertion repair: `installedRendererFactoryInputs: installedRendererFactoryInputs`
became `installedRendererFactoryInputs: routedInstalledRendererFactoryInputs`
when the routing wrapper landed on main, so the count assertion drifted red
independent of this fix.

## Related facts

`architecture.mmd` in the Testbed wiki carries MIME
`application/vnd.chipnuts.karaoke-mmd`. macOS maps `.mmd` to a karaoke UTI,
which bypasses the `text/mermaid` extension fallback in
`MimeType.mime(forExtension:)` because that fallback fires only when UTType
cannot resolve at all. The renderer match still succeeds through the
`.mmd` extension-fallback tier, so this is not the pane bug. But the
`![[source:…]]` embed expansion requires `MimeType.isText`, so the embed
shows "Source not yet extracted." A separate fix could normalize the MIME at
ingest or widen the gate.

## Verification

- `make build` — pass (app built and signed).
- `WIKIFS_APP_TESTS=1 swift test --filter RendererSessionPreparation` —
  11 tests in 3 suites pass, including the 6 new phase tests.
- `WIKIFS_APP_TESTS=1 swift test --filter "SourceDetailRendererArchitectureAuditTests|RendererPresentationStateTests|RendererSessionPreparation"` —
  41 tests in 5 suites pass.
- `make test` — 4192 tests in 456 suites pass.

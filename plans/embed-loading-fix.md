# Plan: Fix embed `![[X]]` stuck on "Loading…" (#725)

## Goal
Fix #725: page/source embeds (`![[PageName]]`, `![[source:X]]`) render the
collapsed `<details>` with the right title, but on expand the body stays on
"Loading…" forever. The lazy JS→Swift fetch never starts.

## Root cause (HIGH confidence — see tmp/sdw-plans/embed-loading-rootcause.md)
`Sources/WikiFS/Reader/WikiReaderView.swift:875` — the `embedFetch`
`WKScriptMessageHandler`:

```swift
func userContentController(_ …, didReceive message: WKScriptMessage) {
    guard let view = target,
          let body = message.body as? [String: String] else { return }   // ❌ ALWAYS FAILS
    view.coordinator?.handleEmbedFetch(body: body)
}
```

The JS posts a **plain object literal** (`WikiReaderView.swift:832-834`):
`window.webkit.messageHandlers.embedFetch.postMessage({ nodeId, kind, id, target, path, name })`.
WKWebView bridges a JS object via `postMessage` to an `NSDictionary` whose
values are boxed as **`Any`** (not `String`). The downcast `as? [String: String]`
requires *every* value to be a `String`; against the `Any`-boxed dictionary it
**always fails** → `body == nil` → `guard … else { return }` silently drops the
message → no fetch → "Loading…" forever, no log, no error. Exact symptom match.

**Ruled out with evidence** (all verified correct): WKUserScript timing (re-injects
on every `loadHTMLString`, same pattern as the working hover listener +
MutationObserver safety net); `embedProxy`→Coordinator wiring; the
`querySelectorAll`/`.sdw-embed-body`/`data-sdw-state="empty"` selectors (match
emitted HTML); `processEmbedFetch` fetch/readPool/error-handling (no bare
`try?`). The existing `TransclusionEmbedTests` construct `Coordinator()` directly
and call `processEmbedFetch(body:)` with a literal `[String: String]` — they
**bypass the broken bridge cast**, which is why the bug shipped.

## Fix
1. **Swap the cast** to the type the bridge actually delivers (`[String: Any]`),
   coerce the expected keys to `String`, and call `handleEmbedFetch(body:)`.
   Extracted as a static `coerceBody(_:)` on `EmbedFetchMessageHandler` so the
   bridge-shape coercion is unit-testable without a live `WKWebView`:
   ```swift
   static func coerceBody(_ raw: Any) -> [String: String]? {
       guard let dict = raw as? [String: Any] else { return nil }
       return ["nodeId", "kind", "id", "target", "path", "name"]
           .reduce(into: [String: String]()) { result, key in
               result[key] = (dict[key] as? String) ?? ""
           }
   }
   ```
   Handler:
   ```swift
   func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
       guard let view = target else { return }
       guard let body = Self.coerceBody(message.body) else {
           DebugLog.reader("embedFetch dropped: unparseable body")
           return
       }
       view.coordinator?.handleEmbedFetch(body: body)
   }
   ```
   Keys (`nodeId`, `kind`, `id`, `target`, `path`, `name`) verified against
   `processEmbedFetch(body:)` at `WikiReaderView.swift:1306-1312` — exact match
   with the JS `postMessage` payload at `:832-834`.
2. **Add the `DebugLog` on the failure branch** so a future regression of this
   class surfaces instead of hanging silently (house rule: no silent swallowing).
3. **Make `EmbedFetchMessageHandler` `internal`** (was `private`) so the test
   module can exercise `coerceBody(_:)` directly.

## Regression test
Add a test that exercises the **bridge-coercion entry point** with an
`NSDictionary`-shaped body (values boxed as `NSString`, NOT a direct
`[String: String]` call) and asserts `coerceBody` returns a correctly-populated
`[String: String]` (the cast that `as? [String: String]` silently dropped).
Mirror `Tests/WikiFSTests/TransclusionEmbedTests.swift` style (Swift Testing:
`@Test`, `#expect`). Add a negative test (non-dict body → `nil`). Keep the
existing `processEmbedFetch`-direct tests.

## Acceptance
- Expanding a page/source embed fetches + renders the target's body within ~1s
  (no more stuck "Loading…"); `data-sdw-state` reaches `loaded`.
- The `embed-fetch` `DebugLog` line appears on expand (visible in Console.app /
  `log stream --predicate 'subsystem=="com.selfdrivingwiki.debug"'`).
- New regression test (bridge coercion) green; existing `TransclusionEmbedTests` green.
- No bare `try?`; no `print` (DebugLog only); `make build && make test` pass.
- **Runtime confirm** (this is a WKWebView-bridge behavior — validate in the
  running app): `make build && make run`; a page with `![[OtherPage]]` → expand →
  body renders. Before the fix there is NO `embed-fetch` log line on expand; after,
  `embed-fetch ok …` appears and the body renders.

## Files
- `Sources/WikiFS/Reader/WikiReaderView.swift` (~L864-878): make class internal,
  add `coerceBody(_:)`, swap cast + add DebugLog.
- `Tests/WikiFSTests/TransclusionEmbedTests.swift` (extend): regression test for
  the bridge coercion.

## Build/test
`make build && make test`. Push the branch, open a PR with `Closes #725`.
**Do NOT merge to main.** Scratch in `tmp/` inside your own worktree.

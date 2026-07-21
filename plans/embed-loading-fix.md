# Plan: Fix embed `![[X]]` stuck on "Loading…" (#725)

## Goal
Fix #725: page/source embeds (`![[PageName]]`, `![[source:X]]`) render the
collapsed `<details>` with the right title, but on expand the body stays on
"Loading…" forever. The lazy JS→Swift fetch never starts.

## Root cause (CONFIRMED at runtime — see tmp/sdw-plans/embed-loading-rootcause.md)
**Two bugs**, both required to produce the symptom:

### Bug 1: `data-sdw-state` on wrong element (PRIMARY — JS never fires)
`Sources/WikiFSLinks/WikiLinkMarkdown.swift:736` — `transclusionEmbedHTML` emits
`data-sdw-state="empty"` on the **inner `.sdw-embed-body` div**:
```html
<details class="sdw-transclusion" ... >  ← NO data-sdw-state
  <summary>…</summary>
  <div class="sdw-embed-body" data-sdw-state="empty">Loading…</div>
</details>
```

But the JS `postEmbed` (`WikiReaderView.swift:821`) reads it from the `<details>` element:
```js
var state = details.getAttribute('data-sdw-state') || '';  // ← reads from <details>
if(state !== 'empty'){ return; }   // ← state is '' → ALWAYS RETURNS → no postMessage
```

`sdwInjectEmbed` sets `data-sdw-state` on **both** the host and body:
```js
host.setAttribute('data-sdw-state', 'loaded');   // sets on <details>
body.setAttribute('data-sdw-state', 'loaded');   // sets on inner div
```

So the JS was designed for the initial `empty` state to be on the `<details>` (host), but the HTML emitted it on the inner div. **The message handler was never called** — confirmed by the absence of ANY `embed-fetch` log line at runtime.

### Bug 2: `WKScriptMessageHandler` cast always fails (SECONDARY — would fail even if JS fired)
`Sources/WikiFS/Reader/WikiReaderView.swift:875` — the cast `message.body as? [String: String]`
always fails because WKWebView bridges JS object literals to `NSDictionary` with `Any`-boxed
values. Fixed by `coerceBody(_:)` casting to `[String: Any]` first.

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

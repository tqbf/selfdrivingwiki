# #669 — Replace merval with mermaid.min.js for v11 syntax validation

## Problem
`MermaidValidator` loads `Resources/merval.bundle.js` into a `JSContext` and calls
`globalThis.__merval.validateMermaid`. merval rejects valid Mermaid 11 syntax like
`A@{ shape: delay }`. The reader was upgraded to Mermaid v11.16.0 (PR #648) but the
validator can't validate v11 diagrams → users can't save pages with v11 diagrams.

## Fix approach
Use `mermaid.min.js` (the SAME v11.16.0 library that renders) for validation. Call
`mermaid.parse(text)` in the JSContext. Eliminates version skew permanently.

## Investigation findings (verified in JSC + Node)

### 1. mermaid.parse() ALWAYS returns a Promise (never throws synchronously)
`mermaid.parse(text)` returns a Promise in both JSC and Node. It does NOT throw
synchronously for invalid input — the error comes via Promise rejection. So the
validator MUST attach `.then`/`.catch` and then **flush the microtask queue** before
reading the result.

### 2. JSC microtask checkpoint
Swift's JavaScriptCore overlay does NOT expose `JSPerformMicrotaskCheckpoint()`
(the C API function). Resolve it via `dlsym` from the system framework:

```swift
func flushMicrotasks() {
    typealias Fn = @convention(c) () -> Void
    if let h = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
       let s = dlsym(h, "JSPerformMicrotaskCheckpoint") {
        unsafeBitCast(s, to: Fn.self)()
    }
}
```

Call `flushMicrotasks()` AFTER `validate.call(withArguments: [text])` and BEFORE
reading the mutated result dict. The Promise's `.then`/`.catch` callbacks fire during
the checkpoint. Verified: ~1.5–2 ms per validation including the checkpoint. Fast
enough for save-time validation.

### 3. DOM polyfill REQUIRED
mermaid.min.js bundles DOMPurify, whose factory returns `undefined` when there is no
`window`/`document`. mermaid then calls `Zs.addHook("beforeSanitizeAttributes", …)`
at runtime → `Zs.addHook is not a function`. This breaks flowchart / classDiagram /
stateDiagram / gantt / journey validation. A minimal DOM stub MUST be installed
BEFORE evaluating mermaid.min.js.

Required stubs (verified sufficient):
- `globalThis.window` (with `document`, `navigator`, `location`, `matchMedia`,
  `requestAnimationFrame`, `cancelAnimationFrame`, `getComputedStyle`)
- `globalThis.document` — must have `implementation.createHTMLDocument()` (DOMPurify
  factory uses it). Provide `createElement`, `createElementNS`, `createTextNode`,
  `createDocumentFragment`, `getElementById`, `getElementsByTagName`,
  `getElementsByClassName`, `querySelector`, `querySelectorAll`, `addEventListener`.
- `globalThis.navigator` (`{ userAgent: '…' }`)
- `globalThis.location` (`{ href, protocol }`)
- `globalThis.setTimeout / clearTimeout / setInterval / clearInterval` —
  JSC has NO timer functions by default. Install no-op stubs.
- `globalThis.structuredClone` — needed by some diagram types (pie). Stub via
  `JSON.parse(JSON.stringify(o))`.
- `globalThis.requestAnimationFrame / cancelAnimationFrame` — no-op stubs.
- `globalThis.matchMedia` — returns `{ matches: false, addListener: Noop, … }`.

A `makeNode(tag)` helper builds a minimal element with the attributes / child-list
API DOMPurify touches. See `tmp/mermaid-test/test_polyfill.swift`
for the full working polyfill source.

### 4. mermaid.initialize() works without DOM
`mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' })` succeeds in
the polyfilled JSContext. No DOM-dependent init path.

### 5. CORRECT v11 syntax (the bug examples were slightly imprecise)
The bug says `@{ icon: "fa:gem" }` and `@{ shape: delay }`. The CORRECT mermaid v11
syntax (verified against official docs + mermaid@11.16.0 in Node) is:

- Shape: `A@{ shape: delay }` (NO square brackets — `@{ … }` attaches directly to
  the node id). `A[@{ shape: delay }]` is INVALID and fails with "Parse error".
- Icon: `A@{ icon: 'fa:gem' }` — same pattern. Additionally icons REQUIRE a
  registered icon pack (`mermaid.registerIconPacks(...)`); without registration the
  icon won't render but the shape grammar still parses `A@{ icon: … }`.

So the validator must accept the CORRECT `A@{ … }` form. merval rejected it; mermaid
v11.16.0's own parser accepts it. This is the core fix.

The bug's literal example `A[@{ shape: delay }]` (inside brackets) IS invalid
mermaid syntax and will (correctly) be rejected by mermaid.parse(). The validator
should NOT special-case it.

### 6. Mermaid is more lenient than merval
mermaid.parse() accepts things merval rejected, e.g. `flowchart LR\n  A B` (two
unconnected words). merval reported `MISSING_ARROW`. With mermaid, this is valid.
Existing tests that assert `MISSING_ARROW` must be updated:
- `MermaidValidatorTests.missingArrowIsInvalid` → either delete or change to a
  genuinely-invalid case (e.g. `flowchart LR\n  A[unclosed`).
- `MermaidValidatorTests.upsertAbortsOnInvalidMermaidBlock` /
  `upsertAbortsBeforeWritingAnInvalidBlock` — the `A B` body is now VALID. Change
  to a genuinely-invalid body.

Genuinely-invalid cases that mermaid.parse() DOES reject (use these in tests):
- `flowchart LR\n  A[unclosed`  → "Parse error on line 3"
- `flyingUnicorns\n  A-->B`      → "No diagram type detected matching given
  configuration for text: flyingUnicorns"
- `` (empty)                    → "No diagram type detected … for text: "
- `this is not mermaid`         → "No diagram type detected …"

### 7. Error shape from mermaid.parse() rejection
The rejection error's `.message` looks like:
```
Parse error on line 2:
flowchart LR  A[unclosed
-----------------^
Expecting 'SQE', 'DOUBLECIRCLEEND', ...
```
or:
```
No diagram type detected matching given configuration for text: flyingUnicorns
```
There is no structured `code` field (merval had `MISSING_ARROW` etc.). Use a single
`code: "PARSE_ERROR"` and extract a line number via `/line\s+(\d+)/i`. The first
line of `.message` is the user-facing summary; keep the rest for diagnostics if
desired but truncate.

### 8. diagramType extraction
mermaid.parse() does NOT return a diagram type. Derive it from the first token of
the first line of the block (e.g. `flowchart` / `graph` / `sequenceDiagram` /
`pie` / `classDiagram` / `stateDiagram-v2` / `erDiagram` / `gantt` / `journey`).
This preserves the existing `BlockResult.diagramType` API.

## Implementation plan

### `Sources/WikiFSMarkdown/MermaidValidator.swift`
1. Keep the public API identical: `init?(jsSource:)`, `validate(markdown:)`,
   `invalidBlocks(markdown:)`, `describe(_:)`, `mermaidBlocks(in:)`, `loadDefault()`,
   `shared`, `BlockResult`, `BlockResult.Issue`. Callers (PageCommand,
   WikiStoreModel) must not change.
2. `init?(jsSource:)`:
   - Install the DOM/timer polyfill (`evaluateScript`).
   - Evaluate the mermaid bundle (`jsSource`).
   - Call `mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' })`.
   - Install the `globalThis.__merval.validateMermaid(text)` wrapper that:
     - Sets `r = { done: false, isValid: false, diagramType: <first token>,
       errors: [] }`.
     - Calls `mermaid.parse(text)`; if it returns a Promise, attach
       `.then(v => { r.done=true; r.isValid=true })`
       `.catch(e => { r.done=true; isValid=false; push error {line, code:'PARSE_ERROR', message} })`.
     - `try/catch` around the synchronous call (defensive — for mermaid builds
       that throw synchronously).
     - Returns `r`.
   - Validate `globalThis.__merval.validateMermaid` is a function; else return nil.
3. `validateSingle(at:source:)`:
   - Call `validate.call(withArguments: [source])`.
   - Call `flushMicrotasks()` (dlsym-resolved `JSPerformMicrotaskCheckpoint`).
   - Read back the (now-mutated) result's `done`/`isValid`/`errors`. If
     `done == false` after the checkpoint (shouldn't happen), report
     `VALIDATOR_ERROR`.
4. `loadDefault()`: resolve `mermaid.js` (not `merval.js`) in the main bundle, then
   the `../Resources/mermaid.js` path relative to the executable. (build.sh already
   copies `Resources/mermaid.min.js` → `mermaid.js` in the bundle.)
5. Doc comment: update to describe the new approach (mermaid.parse, polyfill,
   microtask checkpoint). Note the version-skew elimination and the leniency change.
6. NO bare `try?`. NO `print`. Use `DebugLog` if logging is needed.

### `build.sh`
Remove the `MERVAL_JS` copy block (lines ~177–185). The `MERMAID_JS` copy block
already produces `mermaid.js` in the bundle, which `loadDefault()` now uses for
both rendering AND validation. Leave `Resources/merval.bundle.js` in the repo (per
task: don't delete yet). Optionally update the comment on the `MERMAID_JS` block
to note it's now used for validation too.

### `Tests/WikiFSTests/MermaidValidatorTests.swift`
1. `bundleSource()`: load `../../Resources/mermaid.min.js` (not `merval.bundle.js`).
2. `validator()` error message: update "failed to load __merval.validateMermaid" →
   "failed to load mermaid / install validateMermaid wrapper".
3. Keep all the pure block-extraction tests unchanged.
4. `missingArrowIsInvalid`: `flowchart LR\n  A B` is now VALID. Replace with a
   genuinely-invalid case, e.g. `flowchart LR\n  A[unclosed` and assert
   `errors.isEmpty == false` (drop the `MISSING_ARROW` code assertion — that code
   no longer exists; assert `code == "PARSE_ERROR"` if desired).
5. `crlfInvalidBlockIsCaught`: change the invalid body from `A B` to `A[unclosed`.
6. Add NEW tests:
   - `validV11ShapeSyntaxPasses`: `flowchart LR\n  A@{ shape: delay }` → valid.
   - `validV11ShapeRectPasses`: `flowchart LR\n  A@{ shape: rect }` → valid.
   - (Optional) `invalidBracketAtSyntaxIsCaught`:
     `flowchart LR\n  A[@{ shape: delay }]` → invalid (documents that the
     bracketed form is wrong).
7. `upsertAbortsOnInvalidMermaidBlock` / `upsertAbortsBeforeWritingAnInvalidBlock`:
   change the invalid body from `flowchart LR\n  A B` to `flowchart LR\n  A[unclosed`
   and drop the `MISSING_ARROW` assertion (assert the message contains `mermaid:` +
   `PARSE_ERROR`).
8. `upsertAllowsValidMermaid` / `upsertEndToEndWritesAValidDiagram`: keep (valid
   bodies remain valid).
9. Add a `validV11ShapeSavesEndToEnd` regression test that upserts a body with
   `A@{ shape: delay }` and asserts `didCommit == true`.

### `Tests/WikiFSTests/WikiCtlCommandTests.swift`
1. `repoMermaidValidator()`: load `../../Resources/mermaid.min.js` (not
   `merval.bundle.js`). Update the error message.

### Build + test
```
make version prompts
swift build
swift test
```

### Branch / PR
- Branch: `feature/mermaid-validator-v11` (already created).
- Commit title: `Replace merval with mermaid.min.js for v11 syntax validation (#669)`.
- PR title: same. PR body: `Closes #669`. Do NOT merge.

## Reference scratch tests (under `tmp/`, gitignored — safe to delete after the fix lands)
- `tmp/mermaid-test/test_polyfill.swift` —
  working DOM polyfill + microtask checkpoint, ~1.8 ms/call.
- `tmp/mermaid-test/test_v11forms.swift` —
  proves correct vs incorrect `@{ }` syntax.
- `tmp/mermaid-test/test_node_shapes.js` — Node cross-check (same behavior as JSC).

# Fuzz Harness — Property-Based Parser Fuzzing

## Goal

Hunt memory-safety bugs (precondition failures, force-unwraps, infinite loops,
ASan violations, EXC_BAD_ACCESS) in the pure-logic parser cluster
(`WikiFSLinks` + `WikiFSMarkdown`) by running an open-ended property-based
fuzzer overnight. libFuzzer is NOT available (no custom swift.org toolchain),
so we use a hand-rolled grammar-driven generator + a deterministic PRNG. This
is a standalone executable target, NOT a `swift test` target.

## Deliverable

A new SwiftPM executable target `FuzzHarness` that:

1. Builds with Address Sanitizer:
   `swift build --target FuzzHarness -Xswiftc -sanitize=address`
2. Runs as a standalone binary:
   `.build/debug/FuzzHarness [seed] [iterations]`
3. Runs indefinitely (until Ctrl-C / iteration cap) and prints progress every
   10 000 iterations.
4. Uses a deterministic PRNG (SplitMix64) seeded from `CommandLine.arguments`
   or `time(nil)` so any crash is reproducible by re-passing the seed.
5. Prints the seed + the input about to be fed to a parser before each call,
   so a trap leaves a forensic trail in stdout.

## Parser entry points under test

All targets are `static` / instance-method on a `final class` — none require
a live `WikiStore`. Closures are simulated with fuzzer-controlled stubs.

| # | Symbol | Signature (verbatim) | Source |
|---|--------|----------------------|--------|
| 1 | `WikiLinkParser.parse` | `public static func parse(_ body: String) -> [ParsedLink]` | `Sources/WikiFSLinks/WikiLinkParser.swift:146` |
| 2 | `WikiLinkParser.classify` | `public static func classify(_ target: String) -> (ParsedLink.LinkType, String)` | `WikiLinkParser.swift:48` |
| 3 | `WikiLinkParser.splitFragment` | `public static func splitFragment(_ rawTarget: String) -> (base: String, fragment: String?)` | `WikiLinkParser.swift:77` |
| 4 | `WikiLinkParser.splitVersionPin` | `public static func splitVersionPin(_ base: String) -> (bare: String, pin: String?)` | `WikiLinkParser.swift:105` |
| 5 | `WikiLinkParser.isCanonicalULID` | `public static func isCanonicalULID(_ target: String) -> Bool` | `WikiLinkParser.swift:133` |
| 6 | `WikiLinkParser.isEmptyPrefix` | `public static func isEmptyPrefix(_ target: String) -> Bool` | `WikiLinkParser.swift:58` |
| 7 | `WikiLinkPrefixScanner.openLink` | `public static func openLink(at caret: Int, in text: String) -> OpenWikiLink?` | `Sources/WikiFSLinks/WikiLinkPrefixScanner.swift:57` |
| 8 | `WikiLinkResolver.candidateSplits` | `public static func candidateSplits(of rawTarget: String) -> [Split]` | `Sources/WikiFSLinks/WikiLinkResolver.swift:41` |
| 9 | `WikiLinkResolver.resolvedSplit` | `public static func resolvedSplit(of rawTarget: String, isKnown: (String) throws -> Bool) rethrows -> Split?` | `WikiLinkResolver.swift:54` |
| 10 | `WikiLinkRewriter.canonicalize` | `public static func canonicalize(in body:, resolvePage:, resolveSource:, resolveChat:) throws -> String?` | `Sources/WikiFSLinks/WikiLinkRewriter.swift:27` |
| 11 | `WikiText.normalized` | `public static func normalized(_ s: String) -> String` | `Sources/WikiFSLinks/WikiText.swift:11` |
| 12 | `MarkdownLinter.lint` / `.fix` | `public func lint(markdown: String) -> [LintResult]`, `public func fix(markdown: String) -> FixOutcome` | `Sources/WikiFSMarkdown/MarkdownLinter.swift:157,178` |
| 13 | `WikiFootnoteMarkdown.rendered` | `public static func rendered(_ markdown: String) -> Rendered` | `Sources/WikiFSMarkdown/WikiFootnoteMarkdown.swift:42` |
| 14 | `WikiFootnoteMarkdown.footnoteAnchorID` | `public static func footnoteAnchorID(for id: String) -> String` | `WikiFootnoteMarkdown.swift:68` |
| 15 | `HTMLToMarkdown.convert` | `public static func convert(_ html: String) -> Result` | `Sources/WikiFSMarkdown/HTMLToMarkdown.swift:44` |
| 16 | `HTMLToMarkdown.markdown(from:)` | `public static func markdown(from html: String) -> String` | `HTMLToMarkdown.swift:76` |
| 17 | `HTMLToMarkdown.titleOnly` | `public static func titleOnly(from html: String) -> String?` | `HTMLToMarkdown.swift:71` |
| 18 | `DroppedLinkFormatter.link` | `public static func link(for type:, id:, displayName:) -> String` | `Sources/WikiFSLinks/DroppedLinkFormatter.swift:71` |
| 19 | `DroppedLinkFormatter.markdownList(for:)` | `public static func markdownList(for items: [Item]) -> String` | `DroppedLinkFormatter.swift:82` |

### Notes / caveats

- `MarkdownLinter.lint` / `.fix` need a constructed instance. We use
  `MarkdownLinter.shared` (a process-wide singleton) — when the bundled
  `markdownlint.js` resource is unavailable (which it is in a bare
  `swift build` CLI), `shared` is `nil` and we skip those two targets with
  a startup warning. They will engage when the fuzzer is run from a bundle
  context.
- `WikiLinkRewriter.canonicalize` takes three resolver closures. We supply
  fuzzer-controlled stubs: `(String) -> PageID?` returning either `nil` or a
  random `PageID(rawValue:)`, so the rewriter exercises both the resolve and
  the leave-literal branches.
- `WikiLinkResolver.resolvedSplit` takes `isKnown: (String) throws -> Bool`.
  We supply a stub returning a random Bool, plus occasionally `throw`-ing to
  exercise the `rethrows` propagation.
- `WikiLinkPrefixScanner.openLink(at:in:)` takes a caret offset — we generate
  a random text AND a random caret in `0...text.count` (clamped) so all
  scan-window positions exercise.

## Input generators

A single `FuzzPRNG` (SplitMix64) drives all generators. Each generator
chooses among a weighted set of "shapes" plus a fully-random fallback.

### 1. Wiki-link strings

Produce strings drawn from a grammar that biases toward:

- Well-formed `[[page:ULID|title]]`, `[[source:id]]`, `[[chat:id]]`,
  `[[Title|alias]]`, `[[Page#Section]]`, `[[source:X#"quote"]]`,
  `[[source:ULID@v3]]`, `![[source:ULID]]` (embed).
- Malformed: unclosed `[[`, unopened `]]`, doubled `[[[X]]]`, `[[X|]]`,
  `[[|X]]`, `[[ ]]`, `[[source:]]`, `[[page:   ]]`.
- Pipe bombs: `[[X|||||||||Y]]`, `[[X|Y|Z]]`.
- Nested: `[[a [[b]] c]]`, `[[[[x]]]]`.
- Empty / whitespace targets: `[[\n\t]]`, `[[ ]]`.
- Unicode in titles: emoji, combining marks, RTL, CJK, zero-width joiners.
- Very long: 10KB+ alias, 10KB+ target.
- Raw special chars: only `[`, `]`, `|`, `#`, `"`, `@`, `:`, `!`.
- Null bytes / control chars interspersed (`\u{0}`, `\u{1B}`, `\u{7F}`).

### 2. Markdown strings

Drawn from a generator that biases toward:

- GFM headers (`#` ... `######`), bold/italic (`**x**`, `*x*`, `_x_`),
  inline code (`` `x` ``), fenced blocks (```` ``` ````), task lists,
  blockquotes (`> `), tables, footnotes (`[^id]` + `[^id]: def`).
- Mixed wiki-link + markdown: a paragraph that mixes `[[…]]` with bold/code.
- Deeply nested: 50-level blockquote, 50-level list, deeply italic.
- Empty, single-char, whitespace-only.
- Null bytes / control chars in the middle of code spans.
- 10KB+ bodies.

### 3. HTML strings

Drawn from a generator that biases toward:

- Well-formed `<p>`, `<a href>`, `<strong>`, `<code>`, `<pre>`, `<ul>/<li>`,
  `<img>`, `<title>...</title>`.
- Malformed: unclosed tags, mismatched nesting, `<script>`/`<style>` noise,
  `<` not followed by a tag, raw entities (`&amp;`, `&#0;`, `&#xFFFFFFFF;`),
  deeply nested (50+), very long attributes.
- Empty, single char, control chars.

### 4. Bare target / id strings

For `classify`, `splitFragment`, `splitVersionPin`, `isCanonicalULID`,
`isEmptyPrefix`, `WikiText.normalized`, `WikiFootnoteMarkdown.footnoteAnchorID`:

- Random 26-char Crockford base32 (canonical ULID shape).
- Random lower-case / mixed case strings of length 0–30.
- Strings with `#`, `#"`, `@v3`, `@V3`, `@v`, `@x3`, leading/trailing spaces.
- Very long (10KB+).
- Unicode / control chars / null bytes.

### 5. Raw special-char strings

For the edge-case bucket:

- Empty, `""`, single `"["`, single `"]"`, `"|"`, `"#"`, `"\""`, `"@"`, `":"`.
- Only whitespace (space, tab, newline, `\r`, `\u{2028}`).
- Null bytes only.
- 10KB of a single char (`[`, `]`, `|`, etc.).

## Driver loop

```
seed = argv[1] ?? time(nil)
maxIters = argv[2] ?? Int.max
prng = SplitMix64(seed: seed)
print("FuzzHarness seed=\(seed)")
for i in 0..<maxIters {
    let input = prng.nextInput()           // weighted pick across the 5 generators
    print("seed=\(seed) iter=\(i) kind=\(input.kind) input=\(input.preview)")
    fuzzOne(input, prng: &prng)
    if i % 10_000 == 0 && i > 0 { print("progress iter=\(i)") }
}
```

`fuzzOne` dispatches on `input.kind` and calls the appropriate parser(s). Every
parser call is wrapped in `do { try … } catch { return }` — expected errors are
fine (return 0); only traps / EXC_BAD_ACCESS / SIGABRTs (the things we are
hunting) end the process. The pre-call `print` on the line above is the forensic
trail: when a trap fires, stdout shows exactly which seed / iter / kind / input
triggered it.

The "input about to be fed" line is serialized as a base64 of the raw UTF-8 so
newlines / null bytes in the input do not corrupt the log line.

## Sanitizer

`-Xswiftc -sanitize=address` is documented in the file header and passed on
the build command. We do NOT bake `-sanitize=address` into `unsafeFlags` in
`Package.swift` because SwiftPM refuses to build dependencies with sanitizer
flags when the dependencies themselves aren't built with the sanitizer (it
causes link failures and `-warnings-as-errors` interaction issues). Documenting
the flag on the build command is the documented pattern in `AGENTS.md`-adjacent
projects.

## Dictionary file

`Sources/FuzzHarness/fuzz-dict.txt` — a libFuzzer-style dictionary of wiki-link
and markdown tokens. Property-based fuzzers don't read libFuzzer dictionaries
natively, but the file doubles as a curated token set the generators sample
from (and is ready to feed to a future libFuzzer migration if a custom
toolchain ever becomes available). Tokens:

- `[[`, `]]`, `|`, `![[`, `[[page:`, `[[source:`, `[[chat:`, `[[#`, `#"`,
  `@v1`, `@v3`, `01H`, `01J`, `]]\n`, `[[X|]]`, `[[|]]`
- Markdown: `# `, `## `, `### `, `**`, `*`, `_`, `` ` ``, ```` ``` ````,
  `> `, `- [x] `, `|---|`, `[^id]:`, `[^id]`
- HTML: `<p>`, `</p>`, `<a href="`, `<strong>`, `<code>`, `<pre>`,
  `<title>`, `<script>`, `&amp;`, `&#0;`, `<` (raw), `>` (raw)

## Files

```
Sources/FuzzHarness/
├── main.swift           — PRNG, generators, driver loop, dispatch
└── fuzz-dict.txt        — token dictionary (sampled by generators)
Package.swift            — +1 executableTarget entry (deps on WikiFSLinks,
                          WikiFSMarkdown, WikiFSTypes)
plans/fuzz-harness.md    — this file
```

## Verification

The PR says: `make prompts && swift build --target FuzzHarness` must compile,
and the fuzzer must run for 100 iterations to verify it works. We will run
`.build/debug/FuzzHarness <seed> 100` (no ASan, for build speed) and confirm
it exits cleanly. We will NOT run the full unbounded fuzzer in the worktree.

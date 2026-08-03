# defuddle

Bundled copy of [defuddle](https://github.com/kepano/defuddle) — a
self-contained Node script that extracts article markdown + metadata from
HTML using readability scoring and site-specific parsers (GitHub, Wikipedia,
Substack, YouTube transcripts, …).

Part of [Self Driving Wiki](../..). Replaces the tag-based
`HTMLToMarkdown.scopeToMainContent` heuristic for the HTML-ingestion path
(issue #761).

## Why bundle it

The app already bundles **bun** (a Node-compatible runtime) in
`Contents/Helpers/bun`, required by the build for ACP providers. So defuddle
runs fully self-contained via the bundled bun — no system Node, no uv/Python,
no external runtime dependency. This makes defuddle strictly simpler than
`pdf2md` (which needs unbundled uv+Python and falls back to the agent when
absent).

## Version

- **defuddle 0.19.1** (from `~/.local/lib/node_modules/defuddle`)
- `tools/defuddle/defuddle` is a **`bun build` bundle** of the published
  `dist/cli.js` entry point — ~2.45 MB, 351 modules inlined. It is NOT a
  verbatim copy of `dist/cli.js`: that file is just the CLI entry and has
  unresolvable `require`s when stood alone (`commander`, `./node`, `./utils`,
  `./frontmatter`, `./fetch`, `./utils/linkedom-compat`, …). `bun build`
  resolves and inlines all of them so the resulting file is genuinely
  self-contained and runs directly under bun with no `node_modules`.

## Usage (how the app invokes it)

```sh
echo '<html>…<article><p>Hi <strong>there</strong>.</p></article>…' \
    | bun tools/defuddle/defuddle parse -j -
```

Outputs JSON on stdout with, among others:

- `contentMarkdown` — the extracted markdown (`Hi **there**.`)
- `content` — cleaned HTML (`<article><p>Hi</p></article>`)
- `title`, `author`, `description`, `published`, `wordCount`

### ⚠️ Critical gotcha: use `parse -j -`, NOT `-m -j -`

| Invocation | `content` field | `contentMarkdown` field |
|------------|-----------------|-------------------------|
| `parse -j -` (no `-m`) | cleaned HTML | **markdown** ✓ |
| `parse -m -j -` | markdown (overloaded) | **ABSENT** ✗ |

With `-m -j`, defuddle overloads `content` with markdown and drops
`contentMarkdown`. **Use `parse -j -` and read `contentMarkdown`.** The
JSON decoder prefers `contentMarkdown` and falls back to `content`, so it is
robust to both shapes.

### SPA / empty content

A page with no article body (e.g. `<div id="app">`) makes defuddle exit 1
with empty stdout. This is the fallback trigger
(`DefuddleExtractionService.extract` returns nil → caller uses tag-based
`HTMLToMarkdown`). Input is read from stdin (`-`); the stdin pipe **must be
closed** after writing so defuddle sees EOF.

## Update procedure

```sh
# 1. Install/update defuddle globally (npm)
npm install -g defuddle            # or: npm install -g defuddle@latest

# 2. Resolve the real entry point (the bin is a symlink to dist/cli.js).
#    NOTE: macOS ships BSD readlink (no -f). If this errors, install GNU
#    coreutils (`brew install coreutils`) and use `greadlink -f`, or just
#    hard-code ~/.local/lib/node_modules/defuddle/dist/cli.js.
SRC="$(readlink -f ~/.local/bin/defuddle)"

# 3. Bundle the CLI entry point into a single self-contained file. `bun build`
#    resolves and inlines all of cli.js's requires (commander, ./node, ./utils,
#    ./frontmatter, ./fetch, ./utils/linkedom-compat, …) — 351 modules,
#    ~2.45 MB. A plain `cp "$SRC"` does NOT work: cli.js alone is not
#    self-contained and bun would fail with "Cannot find module './node'".
~/.bun/bin/bun build "$SRC" --outfile tools/defuddle/defuddle --target=bun

# 4. Update the version number in this README and in
#    Sources/WikiFS/Sources/DefuddleExtractionService.swift comments if needed.

# 5. Re-run the test suite
swift test --filter DefuddleExtractionService
```

The bundle is a single self-contained file — no `node_modules`, no install
step at build time. `build.sh` copies it into `Contents/Helpers/defuddle` and
codesigns it (a plain script in `Helpers/` must be signed or the app seal
fails; same as pdf2md).

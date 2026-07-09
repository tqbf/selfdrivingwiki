# Wiki Maintainer Instructions

You maintain this wiki — an LLM-curated knowledge base. The user curates raw
sources and asks questions; you do the bookkeeping: ingest sources, author
summary/entity/concept pages, cross-link them, and keep the curated index and
chronological log current. Organize and summarize, but NEVER discard the
user's raw input — the original sources are immutable and stay verbatim.

You read this document at the start of every run: it is projected read-only at
the wiki root as both `CLAUDE.md` and `AGENTS.md`. The user co-evolves it in
the Self Driving Wiki app over time. Do not edit it through the filesystem.

## Layout

The wiki is projected read-only at `$WIKI_ROOT`. Browse it with
`find`/`cat`/`grep`/`Read`; orient with `$WIKI_ROOT/WIKI-STRUCTURE.md` first.

- `pages/by-title/`, `pages/by-id/` — the wiki pages you author (one file per
  page, addressed by title and by ULID).
- `sources/by-name/`, `sources/by-id/` — raw sources, IMMUTABLE and
  verbatim (the bytes the user added). Cite a source by its `sources/…` path.
- `index.md` — the curated catalog you maintain (rewritten wholesale on ingest).
- `log.md` — the append-only chronological log of ingests/queries/lints.
- `WIKI-STRUCTURE.md` — an orientation map of this layout plus live page/file counts.
- `TREE.md` — legacy alias for `WIKI-STRUCTURE.md`.
- `indexes/*.jsonl` — machine-readable indexes (`pages.jsonl`, `links.jsonl`,
  `sources.jsonl`) for cheap programmatic navigation. `links.jsonl` has a
  `type` field (`"page"` or `"source"`) — the unified link graph spans both.
- `manifest.json` — the generated wiki manifest.
- `CLAUDE.md` / `AGENTS.md` — this document (identical bytes).

## Conventions

- **Page titles** are the identity of a page — clear, specific, and stable
  (`Calvin Cycle`, not `the cycle`). Upserting an existing title updates it.
- **`[[wiki links]]`** cross-reference other pages: write `[[Page Title]]` in a
  body, or `[[Target|alias]]` to show different link text. Link entities and
  concepts to their own pages so the graph stays connected.
- **Summarize, don't discard.** Condense long or messy sources into pages, but
  the raw source under `sources/` is the system of record — cite it, never
  replace it.
- **Entity pages** describe one thing (a person, place, organization, system):
  what it is, key facts, and links to related pages.
- **Concept pages** explain one idea or process: a definition, how it works,
  and links to the entities and concepts it touches.
- **Cite sources** by their `sources/…` path so a claim can be traced back to the
  bytes it came from. Prefer passage-level citations with `[[source:Name#"…"]]`
  (see Footnotes & Citations below).
- **Link to source passages by distinctive quote** —
  `[[source:Smith2023#"the effect vanishes above 40°C"]]`. The `#"…"` goes AFTER
  the source name with NO pipe (`|`). The quote makes the link scroll to that
  exact passage when clicked. Pick a snippet unique to that passage; it survives
  re-extraction. The quote is whitespace-normalized and case-sensitive.
- **Version pins (`@vN`) freeze a quote against re-extraction.** Append `@vN`
  before the `#"…"` to pin the Nth extraction (oldest = `v1`):
  `[[source:Smith2023@v3#"the effect vanishes above 40°C"]]`. The link then
  opens *that* extraction — so the quote highlight survives even if the source
  is re-extracted later (HEAD moves, `@v3` stays). Use this for citations that
  must remain stable; omit `@vN` to follow the latest extraction.
- **Link to page sections by heading** — `[[Overview#Methodology]]`. The heading
  text becomes a URL-style slug (lowercase, spaces→`-`, punctuation dropped,
  `-1/-2` suffix on duplicates). Same-page scroll: `[[#Methodology]]`.
- **`#` is NOT `|`.** `[[source:X|alias]]` changes the DISPLAY TEXT. `[[source:X#"quote"]]`
  scrolls to a PASSAGE. They do different things. Never use `|` in a footnote
  citation — the source's display name IS the link text.
- **Footnotes** cite evidence at the passage level. Use `[^id]` inline (any label;
  auto-numbered 1,2,3… in output) and `[^id]: definition` on its own line after
  the paragraph that references it. Definitions accept full markdown including
  `[[links]]` and may span indented continuation lines. Example:

  ```
  The Calvin cycle has three phases.[^calvin]

  [^calvin]: See [[source:Bassham1950#"the dark reactions of photosynthesis"]]
  for the original discovery, and [[Calvin Cycle#Regulation]] for regulatory
  mechanisms.
  ```

  WRONG (do NOT do this):
  ```
  [^def]: [[source:Bassham1950|Bassham (1950)]], *JACS* 72: 456–460. Anchor: "the dark reactions..."
  ```
  This is wrong because: (a) `|` changes display text instead of linking a passage,
  (b) journal/DOI metadata doesn't belong in a wikilink citation, (c) the quote
  goes after `#"…"` inside the link, not as "Anchor:" text.
- **`[[source:Name]]`** (without a passage) navigates to the source and opens its
  extracted/text content — use for general references; add `#"…"` for specific
  passages. The canonical cite target is the source's **display name**; you may
  rename a source with `$WIKICTL source rename --id <id> --to "New Name"` —
  renames never orphan citations (see Canonical links below).
- **`![[source:Name]]`** (embed) renders a source's content INLINE in the page
  reader — `<img>` for images, `<video>`/`<audio>` for media, `<iframe>` for
  PDFs. The `!` prefix goes before `[[`, exactly like Obsidian. Images are the
  primary use case (embed a diagram or figure that lives as a source). The
  syntax is **source-only** (`![[Page]]` is not valid — use Mermaid for
  diagrams instead). Unresolved embeds render as ghost links.
- **External media embeds.** Pasting a media URL (YouTube, Vimeo, Spotify,
  SoundCloud, or a direct `.mp3`/`.mp4`/`.m3u8` link) via Add URL creates a
  *byteless* source — no bytes are fetched, it's just a pointer. Embed it with
  `![[source:Name]]` and the page reader renders the provider player
  (`<iframe>`) or a native `<audio>`/`<video>` for direct media. Existing
  episode-transcript sources (audio-player providers) embed their player the
  same way.
- **Canonical links.** At save time every resolvable `[[Title]]` /
  `[[source:Name]]` is normalized to a ULID-stable form —
  `[[page:01H…|Title]]` / `[[source:01J…|Name]]` — where the ULID is the
  target's permanent id and the text after `|` is the human-readable alias.
  **Authoring is unchanged**: keep writing plain titles; the store
  canonicalizes for you. If you read back a page and see `[[page:01H…|Title]]`,
  that is the canonical form — leave it as-is, do NOT rewrite it back to a bare
  title. Renames self-heal at render (the alias is stale but the display shows
  the current name), so a `source rename` or a page re-title never rewrites
  other pages' bodies.
- **Link to chats** — `[[chat:Title]]` navigates to a persisted chat
  (Ask or Edit). Find the title with `wikictl chat list` (or `wikictl chat search`
  to find one by meaning); read a transcript with `wikictl chat get --id <id>` or
  `--title "Title"`. Chats project as `chats/by-id/<ULID>.md` on the mount. The
  canonical form `[[chat:01J…|Title]]` is stable across renames. Chat links
  cannot be embeds (`![[chat:…]]` is invalid). **Use this syntax whenever you
  reference a past chat** — in a page you write (`[[chat:Title]]` alongside the
  page's other wikilinks) or in your reply within the current conversation
  (e.g. "we discussed this in [[chat:Title]]") — rather than describing the
  chat in prose. This is how a reader (or the app) navigates straight to it.
  To cite a specific message, append a quote anchor —
  `[[chat:Title#"distinctive passage"]]` (the `#"…"` wraps a substring that
  appears in the transcript); it opens the chat, scrolls to that message, and
  highlights the passage.
- **External sources** (papers, books, URLs NOT ingested into this wiki) get
  standard academic footnote citations: `[^id]: Author (Year), "Title", Journal/
  Publisher. DOI or URL`. If only a URL is available, that's fine. External
  citations go in footnotes just like wiki-source citations — the only difference
  is the definition format. Example:
  `[^rosenthal]: Rosenthal (2002), "Explaining Consciousness", in Philosophy of
  Mind: Classical and Contemporary Readings.`
- **Diagrams (Mermaid).** Render a diagram with a fenced block whose opening
  fence is exactly ` ```mermaid ` (lowercase). Supported: `flowchart` (prefer
  over `graph`), `sequenceDiagram`, `classDiagram`, `stateDiagram-v2`,
  `erDiagram`, `gantt`, `pie`, `gitGraph`, `mindmap`, `timeline`. Mermaid is
  finicky about syntax — the rules below prevent ~90% of failures, and `wikictl
  page upsert` validates every block on save, so a broken diagram is rejected
  (fix what `wikictl` reports, then re-save):
  - **Quote any label with a special character.** `( ) [ ] { } / \ : ; # @ ! ?
    < >` all break parsing. Write `A["Step 1: Initialize"]`, not
    `A[Step 1: Initialize]`.
  - **Reserved words are not node IDs.** `end`, `default`, `style`, `class`,
    `click`, `call`, `href` break diagrams. Use a safe ID + quoted label —
    `end1["end"]` — or capitalize: `End`.
  - **Avoid node IDs starting with `o` or `x`** (they create special edge
    types); use descriptive IDs like `orderNode`, not `oNode`.
  - **Comments are `%%`**, never a single `%`. **Sequence-diagram semicolons**
    are line breaks — use `#59;` for a literal `;`: `A->>B: key#59;value`.
  - **Subgraph titles with special chars or `<br/>` need quotes:**
    `subgraph "Phase<br/>Two"`.
  - Minimal valid example:

  ```mermaid
  flowchart LR
      Start["Start"] --> Check{"Ready?"}
      Check -->|yes| Done["Done"]
      Check -->|no| Start
  ```

  Diagrams render inline in the reader and match light/dark appearance.

## Tooling — write via `wikictl`, never the filesystem

The mount is READ-ONLY. All writes go through `wikictl`, which writes straight to
the wiki's database. **Always invoke it as `$WIKICTL`** — that variable holds its
absolute path and resolves regardless of your shell's PATH (a bare `wikictl` works
in most shells too, but `$WIKICTL` always does). It already targets THIS wiki via
the `WIKI_DB` environment variable — do NOT pass `--wiki`.

**Markdown auto-normalizes on save.** `$WIKICTL page upsert` strips trailing
whitespace, converts tabs to spaces, collapses extra blank lines, ensures
blank lines around headings/fences/lists/tables, and guarantees a single
trailing newline — automatically. You don't need to hand-format whitespace;
focus on content and structure.

Write page and index bodies to a FILE in your current working directory, then pass `--body-file <path>`. NEVER pipe or heredoc the body (`printf '<body>' | … --body-file -`, `wikictl … <<EOF`): the sandbox blocks the heredoc's temp file, the body arrives empty, and `wikictl` refuses an empty body.

```
$WIKICTL page list                          list id / title / path per page
$WIKICTL page get --title T | --id I        print a page body (instant, authoritative)
$WIKICTL page upsert --title T --body-file ./body.md   create or update a page
$WIKICTL page delete --id I                 delete a page
$WIKICTL index set --body-file ./index.md   rewrite index.md wholesale
$WIKICTL log append --kind ingest|query|lint --title "…" [--note "…"] [--source <file-id>]  record an action (--source marks an ingest done)
$WIKICTL search --query "…" [--limit N]    semantic search — find pages by meaning; defaults to 10 results, max 100
$WIKICTL source list [--json]               list all sources (TSV, or JSON lines)
$WIKICTL source cat --id I | --name N       write raw source bytes to stdout
$WIKICTL source export --id I | --name N [--out <path>]
                                            materialize a source to disk, print its path
$WIKICTL source search --query "…" [--limit N]   semantic search of sources — find source material by meaning; defaults to 10, max 100
$WIKICTL chat list [--json]                   list chats (id / title / kind / message count)
$WIKICTL chat get --id I | --title T          print a chat transcript as markdown
$WIKICTL chat search --query "…" [--limit N]  semantic search of chats — find past conversations by meaning; defaults to 10, max 100
```

**Read back what you just wrote with `$WIKICTL page get`** — the mount lags a
few seconds behind the database, so `cat`-ing a path under `$WIKI_ROOT`
immediately after a write may show stale bytes. `$WIKICTL page get` reads the
database directly and is always current.

**Search is semantic — match by meaning, not keywords.** `$WIKICTL search`
(pages), `$WIKICTL source search` (sources), and `$WIKICTL chat search` (past
conversations) all rank by similarity, so phrase a query as a concept or whole
question ("continuous profiling with JFR") rather than a bare word. Output is
ranked `id<TAB>title` (or `id<TAB>name`) lines, best match first; read a hit with
`$WIKICTL page get --id <id>`, `source cat` / `source export` for sources, or
`chat get` for a conversation transcript. Example:

```
$ $WIKICTL search --query "continuous profiling with JFR"
01KW0Z02Z311SAAQ3BA831910D	Java Flight Recorder
01KW0Z03W0RMBR4AP8GVBGTPCC	JFR Production Profiling
→ $ $WIKICTL page get --id 01KW0Z02Z311SAAQ3BA831910D
```

## Sources

Most sources already have their text extracted. `sources.jsonl` includes a
`has_markdown` flag — a source so flagged has a `<id>.md` sibling in
`sources/by-id/` holding the extracted text (the latest conversion or edit).
READ THAT `.md` — it is the source's content as plain text. Do NOT render or
otherwise try to extract the raw PDF when a `.md` sibling exists; the extraction
is already done for you. Only for a source WITHOUT extracted markdown do you
`Read` the raw file directly — the `Read` tool handles text, images, and PDFs;
for a PDF read the text first, and view any figures you need as images
separately. `sources.jsonl` gives metadata and `source cat` the raw bytes; to
find source **content** by meaning, use `$WIKICTL source search --query "…"`
(semantic — works across PDFs and text).

**Website snapshots:** a fetched web page that includes content images stores
as a self-contained snapshot — the page's markdown plus its images as sibling
sources (role `media`, filtered from the main Sources list). Image references
in the stored markdown use relative paths (`![](images/foo.png)`) that resolve
to the stored image blobs, rendering **offline and inline** with no network
dependency. A webpage that includes images cannot be refreshed until
snapshot-aware refresh is implemented (the guard reports this clearly).

## Workflows

**Ingest** — bring one raw source into the wiki:
1. Read the source (`Read` for PDFs/images, `cat` for text).
2. Check for relevant prior discussion: `$WIKICTL chat search --query "…"` for
   the source's topic, and `$WIKICTL chat get --id I` on any promising hit —
   incorporate what the user already cared about into the pages you write, and
   cite the chat itself with `[[chat:Title]]` (see Link to chats above). This
   is a quick, targeted lookup, not a mount exploration.
3. Write at least one summary page capturing its key content via
   `$WIKICTL page upsert`. FOOTNOTE EVERY CLAIM drawn from the source with
   `[^id]` + `[^id]: [[source:DisplayName#"distinctive quote"]]` — see the
   Footnotes convention above for exact syntax.
4. Create or update the entity/concept pages it mentions, cross-linking with
   `[[wiki links]]`.
5. Rewrite `index.md` via `$WIKICTL index set` so the catalog lists the pages
   you just wrote (read the current set with `$WIKICTL page list` first).
6. Record it: `$WIKICTL log append --kind ingest --source <file-id> --title "<source>" --note "…"`.
   The `--source <file-id>` (given in the ingest task as SOURCE_ID) marks the
   file Ingested in the app — always pass it on a successful ingest.

**Query** — answer a question from the wiki:
1. Search: start with `$WIKICTL search --query "…"` for semantic (meaning-based)
   search across page bodies. If that misses, fall back to `$WIKICTL page list`,
   then `$WIKICTL page get`; `grep`/`cat` over `index.md`, `log.md`, and
   `WIKI-STRUCTURE.md`.
2. Answer concisely, CITING page titles with `[[wiki links]]` and source passages
   with `[^id]` + `[^id]: [[source:Name#"quote"]]` footnotes (see Footnotes
   convention above). If the wiki lacks the information, say so plainly rather
   than guessing.
3. Optionally file a useful answer back as a page via `$WIKICTL page upsert`,
   then `$WIKICTL log append --kind query --title "<the question>"`.

**Lint** — health-check the wiki:
1. Survey pages (`$WIKICTL page list`/`page get`), the link graph
   (`indexes/links.jsonl`), `index.md`, and `log.md`.
2. Report contradictions, stale claims, orphan pages (no inbound `[[links]]`),
   missing cross-references, and concepts mentioned repeatedly but lacking a
   page.
3. Record it: `$WIKICTL log append --kind lint --title "Wiki lint" --note "…"`.
   You may also file the report as a page. Only add cross-reference links you
   are confident about; don't rewrite existing page content.

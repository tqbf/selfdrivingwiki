# Wiki Layout (WIKI-STRUCTURE.md)

A read-only map of this Self Driving Wiki wiki. Everything under the mount is served
read-only — WRITE only through the `wikictl` command (see the cheatsheet
below). `wikictl` already targets THIS wiki via the `$WIKI_DB` environment
variable, so never pass `--wiki`.

Current contents: {{pageCount}} page{{pageNoun}}, {{sourceCount}} source{{sourceNoun}}, {{chatCount}} chat{{chatNoun}}.

## Layout

- `index.md`          — the curated catalog; rewrite wholesale via `wikictl index set`.
- `log.md`            — append-only chronological log (grep-able `## [date] kind | title`).
- `WIKI-STRUCTURE.md` — this orientation map.
- `TREE.md`           — legacy alias for `WIKI-STRUCTURE.md`.
- `CLAUDE.md` / `AGENTS.md` — the agent system prompt (identical bytes).
- `manifest.json`     — generated wiki manifest (page/source/chat counts, generated_at).
- `pages/by-title/`   — one file per wiki page, named by title.
- `pages/by-id/`      — the same pages, named by ULID.
- `sources/by-name/`  — raw immutable sources, named by original filename.
- `sources/by-id/`    — the same sources, named by ULID.
- `chats/by-name/`    — one file per persisted chat, named by title.
- `chats/by-id/`      — the same chats, named by ULID.
- `indexes/pages.jsonl`   — machine index of every page (id, title, path).
- `indexes/links.jsonl`   — machine index of the [[wiki-link]] graph.
- `indexes/sources.jsonl` — machine index of every source.
- `indexes/chats.jsonl`   — machine index of every chat.

## wikictl cheatsheet

- `wikictl page list`                         — id / title / path per page.
- `wikictl page get --title T` (or `--id I`)  — print a page body (instant, authoritative).
- `wikictl page add --title T --body-file ./body.md`  — create/update a page.
- `wikictl index set --body-file ./index.md`             — rewrite index.md.
- `wikictl log append --kind ingest|query|lint --title "…" [--note "…"]` — record an action.

Pass page/index bodies via a FILE (`--body-file <path>`), never a shell pipe
or heredoc — the sandbox drops a piped/heredoc'd body and `wikictl`
refuses an empty body. After any write, read it back with `wikictl page get` — the
read-only mount lags a few seconds, so don't `cat` the mount to verify a fresh write.

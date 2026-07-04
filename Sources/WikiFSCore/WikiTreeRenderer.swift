import Foundation

/// Pure, deterministic rendering of the wiki's layout orientation map (Phase C).
///
/// `WIKI-STRUCTURE.md` and its legacy alias `TREE.md` are read-only root-level
/// documents — projected like `index.md` / `log.md` — that hand a managing agent
/// (or a human browsing the mount) a concrete map of the wiki's layout the moment
/// it lands, so it doesn't waste turns probing for structure (`ls`, `env`, `mount`,
/// `wikictl --help`). The live Phase-C gate showed the agent burning ~6 turns
/// doing exactly that; this map, plus the in-prompt layout, removes the need.
///
/// The layout is FIXED (the projection's tree never changes shape per wiki), so
/// the body is **static per wiki** EXCEPT two cheap live counts (pages, sources)
/// folded in at the top. That keeps it deterministic and simple. Because the
/// counts move with the same `pageCount`/`sourceCount` folds the whole-database
/// `changeToken()` already tracks, the projection versions `TREE.md` by the change
/// token (exactly like `log.md`) so an ingest that adds a page refreshes the
/// counts — see `Projection.treeNode(for:)`.
public enum WikiTreeRenderer {

    /// Render the `TREE.md` body for a wiki with `pageCount` pages and `sourceCount`
    /// sources. Deterministic: same counts → identical bytes.
    public static func render(pageCount: Int, sourceCount: Int) -> String {
        """
        # Wiki Layout (WIKI-STRUCTURE.md)

        A read-only map of this Self Driving Wiki wiki. Everything under the mount is served
        read-only — WRITE only through the `wikictl` command (see the cheatsheet
        below). `wikictl` already targets THIS wiki via the `$WIKI_DB` environment
        variable, so never pass `--wiki`.

        Current contents: \(pageCount) page\(pageCount == 1 ? "" : "s"), \
        \(sourceCount) source\(sourceCount == 1 ? "" : "s").

        ## Layout

        - `index.md`          — the curated catalog; rewrite wholesale via `wikictl index set`.
        - `log.md`            — append-only chronological log (grep-able `## [date] kind | title`).
        - `WIKI-STRUCTURE.md` — this orientation map.
        - `TREE.md`           — legacy alias for `WIKI-STRUCTURE.md`.
        - `CLAUDE.md` / `AGENTS.md` — the agent system prompt (identical bytes).
        - `manifest.json`     — generated wiki manifest (page/source counts, generated_at).
        - `pages/by-title/`   — one file per wiki page, named by title.
        - `pages/by-id/`      — the same pages, named by ULID.
        - `sources/by-name/`  — raw immutable sources, named by original filename.
        - `sources/by-id/`    — the same sources, named by ULID.
        - `indexes/pages.jsonl`   — machine index of every page (id, title, path).
        - `indexes/links.jsonl`   — machine index of the [[wiki-link]] graph.
        - `indexes/sources.jsonl` — machine index of every source.

        ## wikictl cheatsheet

        - `wikictl page list`                         — id / title / path per page.
        - `wikictl page get --title T` (or `--id I`)  — print a page body (instant, authoritative).
        - `wikictl page upsert --title T --body-file ./body.md`  — create/update a page.
        - `wikictl index set --body-file ./index.md`             — rewrite index.md.
        - `wikictl log append --kind ingest|query|lint --title "…" [--note "…"]` — record an action.

        Pass page/index bodies via a FILE (`--body-file <path>`), never a shell pipe
        or heredoc — the sandbox drops a piped/heredoc'd body and `wikictl` refuses an
        empty body. After any write, read it back with `wikictl page get` — the
        read-only mount lags a few seconds, so don't `cat` the mount to verify a fresh write.

        """
    }
}

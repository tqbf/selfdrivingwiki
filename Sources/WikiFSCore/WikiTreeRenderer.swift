import Foundation

/// Pure, deterministic rendering of the wiki's `TREE.md` orientation map (Phase C).
///
/// `TREE.md` is a read-only root-level document — projected like `index.md` /
/// `log.md` — that hands a managing agent (or a human browsing the mount) a
/// concrete map of the wiki's layout the moment it lands, so it doesn't waste
/// turns probing for structure (`ls`, `env`, `mount`, `wikictl --help`). The live
/// Phase-C gate showed the agent burning ~6 turns doing exactly that; this map,
/// plus the in-prompt layout, removes the need.
///
/// The layout is FIXED (the projection's tree never changes shape per wiki), so
/// the body is **static per wiki** EXCEPT two cheap live counts (pages, files)
/// folded in at the top. That keeps it deterministic and simple. Because the
/// counts move with the same `pageCount`/`fileCount` folds the whole-database
/// `changeToken()` already tracks, the projection versions `TREE.md` by the change
/// token (exactly like `log.md`) so an ingest that adds a page refreshes the
/// counts — see `Projection.treeNode(for:)`.
public enum WikiTreeRenderer {

    /// Render the `TREE.md` body for a wiki with `pageCount` pages and `fileCount`
    /// ingested files. Deterministic: same counts → identical bytes.
    public static func render(pageCount: Int, fileCount: Int) -> String {
        """
        # Wiki Layout (TREE.md)

        A read-only map of this WikiFS wiki. Everything under the mount is served
        read-only — WRITE only through the `wikictl` command (see the cheatsheet
        below). `wikictl` already targets THIS wiki via the `$WIKI_DB` environment
        variable, so never pass `--wiki`.

        Current contents: \(pageCount) page\(pageCount == 1 ? "" : "s"), \
        \(fileCount) ingested file\(fileCount == 1 ? "" : "s").

        ## Layout

        - `index.md`          — the curated catalog; rewrite wholesale via `wikictl index set`.
        - `log.md`            — append-only chronological log (grep-able `## [date] kind | title`).
        - `TREE.md`           — this orientation map.
        - `CLAUDE.md` / `AGENTS.md` — the agent system prompt (identical bytes).
        - `manifest.json`     — generated wiki manifest (page/file counts, generated_at).
        - `pages/by-title/`   — one file per wiki page, named by title.
        - `pages/by-id/`      — the same pages, named by ULID.
        - `files/by-name/`    — raw immutable ingested sources, named by original filename.
        - `files/by-id/`      — the same raw sources, named by ULID.
        - `indexes/pages.jsonl` — machine index of every page (id, title, path).
        - `indexes/links.jsonl` — machine index of the [[wiki-link]] graph.
        - `indexes/files.jsonl` — machine index of every ingested file.

        ## wikictl cheatsheet

        - `wikictl page list`                         — id / title / path per page.
        - `wikictl page get --title T` (or `--id I`)  — print a page body (instant, authoritative).
        - `printf '%s' "<body>" | wikictl page upsert --title T --body-file -`  — create/update a page.
        - `printf '%s' "<body>" | wikictl index set --body-file -`              — rewrite index.md.
        - `wikictl log append --kind ingest|query|lint --title "…" [--note "…"]` — record an action.

        After any write, read it back with `wikictl page get` — the read-only mount
        lags a few seconds, so don't `cat` the mount to verify a fresh write.

        """
    }
}

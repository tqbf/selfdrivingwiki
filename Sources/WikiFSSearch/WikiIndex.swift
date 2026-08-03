import Foundation

/// The curated catalog document — a single, app-wide singleton (NOT a wiki page),
/// modeled EXACTLY on `SystemPrompt`. The managing agent rewrites it wholesale on
/// each ingest (via `wikictl index set`); the File Provider projection surfaces
/// its body read-only at the wiki root as `index.md`. Kept out of the `pages/`
/// namespace and distinct from the machine `indexes/*.jsonl`.
///
/// Persisted as one row in the `wiki_index` table (`id = 1`). Carries a `version`
/// (bumped on every write) so it folds into the whole-database `changeToken()`
/// sync anchor — editing ONLY the index must still advance the anchor or the
/// projected `index.md` would never refresh.
public struct WikiIndex: Equatable, Sendable {
    public var body: String
    public var updatedAt: Date
    public var version: Int

    public init(body: String, updatedAt: Date, version: Int) {
        self.body = body
        self.updatedAt = updatedAt
        self.version = version
    }

    /// Seeded into a fresh DB (the v4→5 migration) and used as the projection's
    /// fallback when the row/table can't be read (e.g. a read connection opened
    /// against a not-yet-migrated DB), so `index.md` always exists.
    ///
    /// Inlined from `prompts/wiki-index-default.md` (codegenned into
    /// `GeneratedPrompts.wikiIndexDefault` in WikiFSCore) to avoid a circular
    /// dependency: WikiFSSearch → WikiFSCore → WikiFSSearch. Update both if
    /// the copy changes (it rarely does — it's a one-time seed).
    public static let defaultBody: String = #"""
# Welcome to Your Wiki

This is the home page (`index.md`). The agent maintains it — edit it directly
or ask the agent to update it. When you ingest sources, the agent rewrites this
catalog to list the resulting pages.

## Getting Started

- **Add sources** — drop PDFs or Markdown files, or paste a URL (YouTube,
  websites) into the Sources panel.
- **Ingest** — the agent reads each source and writes wiki pages, cross-linked
  with `[[wiki links]]`, then rewrites this page to catalog them.
- **Ask questions** — use the Ask tab to chat with the agent about your wiki's
  content; it searches and cites from what's here.
- **Edit pages** — double-click any page to edit; changes save automatically.

## Wiki Structure

- `index.md` — this page, the home page and curated catalog.
- `log.md` — chronological changelog of agent activity (ingests, queries, lints).
- `CLAUDE.md` / `AGENTS.md` — the agent's system prompt (one file, two names).
- **Pages** — your content, connected with `[[wiki links]]`.
- **Sources** — original materials (PDFs, URLs, transcripts), stored verbatim.

## Recent Changes

*(The agent appends to `log.md` and refreshes this catalog after each ingest or
edit. Check `log.md` for the full history.)*

## Quick Links

*(Add your most-used pages here with `[[Page Title]]` links once you have them.)*
"""#
}

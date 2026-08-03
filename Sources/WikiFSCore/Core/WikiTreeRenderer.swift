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

    /// Render the `TREE.md` body for a wiki with `pageCount` pages,
    /// `sourceCount` sources, and `chatCount` chats. Deterministic: same counts
    /// → identical bytes.
    public static func render(pageCount: Int, sourceCount: Int, chatCount: Int) -> String {
        PromptTemplate.fill(GeneratedPrompts.wikiTreeRender, [
            "pageCount": "\(pageCount)",
            "pageNoun": pageCount == 1 ? "" : "s",
            "sourceCount": "\(sourceCount)",
            "sourceNoun": sourceCount == 1 ? "" : "s",
            "chatCount": "\(chatCount)",
            "chatNoun": chatCount == 1 ? "" : "s",
        ])
    }
}

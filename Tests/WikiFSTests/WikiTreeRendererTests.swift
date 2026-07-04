import Foundation
import Testing
@testable import WikiFSCore

/// Phase C: the pure `WikiTreeRenderer` that produces the wiki's layout
/// orientation map. The body is deterministic for a fixed pair of counts and
/// carries the fixed layout + the `wikictl` cheatsheet, so a managing agent (and a
/// human browsing the mount) has the map without probing for structure — the gap
/// the live Phase-C gate exposed.
struct WikiTreeRendererTests {

    @Test func rendersTheFixedLayoutAndCheatsheet() {
        let body = WikiTreeRenderer.render(pageCount: 3, sourceCount: 2)
        // The full projection layout the agent needs to navigate.
        #expect(body.contains("index.md"))
        #expect(body.contains("log.md"))
        #expect(body.contains("WIKI-STRUCTURE.md"))
        #expect(body.contains("TREE.md"))
        #expect(body.contains("legacy alias"))
        #expect(body.contains("CLAUDE.md"))
        #expect(body.contains("pages/by-title/"))
        #expect(body.contains("pages/by-id/"))
        #expect(body.contains("sources/by-name/"))
        #expect(body.contains("sources/by-id/"))
        #expect(body.contains("indexes/"))
        // The wikictl cheatsheet uses the file-first body delivery form.
        #expect(body.contains("wikictl page upsert --title T --body-file ./body.md"))
        #expect(body.contains("wikictl index set --body-file ./index.md"))
        #expect(body.contains("wikictl log append"))
        // Mount discipline.
        #expect(body.contains("read-only"))
        #expect(body.contains("do not pass `--wiki`") || body.contains("never pass --wiki")
            || body.contains("never pass `--wiki`"))
    }

    @Test func foldsInTheLiveCounts() {
        let body = WikiTreeRenderer.render(pageCount: 7, sourceCount: 4)
        #expect(body.contains("7 pages"))
        #expect(body.contains("4 sources"))
    }

    @Test func singularizesCountsOfOne() {
        let body = WikiTreeRenderer.render(pageCount: 1, sourceCount: 1)
        #expect(body.contains("1 page,"))
        #expect(body.contains("1 source."))
        #expect(!body.contains("1 pages"))
        #expect(!body.contains("1 sources"))
    }

    @Test func isDeterministicForFixedCounts() {
        // Same counts → byte-identical body (no timestamps / nondeterminism).
        #expect(WikiTreeRenderer.render(pageCount: 5, sourceCount: 9)
            == WikiTreeRenderer.render(pageCount: 5, sourceCount: 9))
    }
}

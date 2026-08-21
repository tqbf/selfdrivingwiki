import Foundation
import Testing
@testable import WikiFSCore

/// Pure tests for the editor-only projection of ULID-canonical wiki links.
/// Stored Markdown remains canonical; this projection only changes what the
/// page editor shows while it is mounted.
struct WikiLinkEditorProjectionTests {
    private let pageID = "01HXXXXXXXXXXXXXXXXXXXXXXX"
    private let sourceID = "01JYYYYYYYYYYYYYYYYYYYYYYY"
    private let chatID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"

    @Test func hidesCanonicalPageIDAndAlias() {
        let body = "See [[page:\(pageID)|Home]] for details."

        #expect(WikiLinkEditorProjection.displayed(body) == "See [[Home]] for details.")
    }

    @Test func keepsNonPageNamespaceWhileHidingCanonicalID() {
        let body = "[[source:\(sourceID)|Paper]] and [[chat:\(chatID)|Standup]]"

        #expect(WikiLinkEditorProjection.displayed(body) ==
                "[[source:Paper]] and [[chat:Standup]]")
    }

    @Test func preservesEmbedFragmentAndVersionPin() {
        let body = "![[source:\(sourceID)@v3#\"Quote\"|Paper]]"

        #expect(WikiLinkEditorProjection.displayed(body) ==
                "![[source:Paper@v3#\"Quote\"]]")
    }

    @Test func leavesCodeAndUnresolvedLinksUntouched() {
        let body = "`[[page:\(pageID)|Home]]` and [[Missing]]"

        #expect(WikiLinkEditorProjection.displayed(body) == body)
    }

    @Test func projectionIsIdempotent() {
        let body = "[[page:\(pageID)|Home]] and [[source:\(sourceID)|Paper]]"
        let displayed = WikiLinkEditorProjection.displayed(body)

        #expect(WikiLinkEditorProjection.displayed(displayed) == displayed)
    }
}

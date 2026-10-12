import Foundation
import Testing
@testable import WikiFSCore

/// `ChatAttachmentTarget` is the typed mixed-target carrier for the chat
/// attachment hand-off. Its case tag is what keeps the `PageID` and
/// `SourceID` namespaces apart: a page and a source whose raw ULID text is
/// identical must never compare equal, at the target level or downstream as
/// composer chips (the chip level is pinned in
/// `ChatComposerAttachmentModelTests`, which can see the app-internal
/// `ChatAttachment` type).
struct ChatAttachmentTargetTests {

    @Test("a page and a source with identical raw text stay distinct targets")
    func pageAndSourceWithIdenticalRawTextStayDistinct() {
        let page = ChatAttachmentTarget.page(PageID(rawValue: "01HIDENTICALRAW"))
        let source = ChatAttachmentTarget.source(SourceID(rawValue: "01HIDENTICALRAW"))
        #expect(page != source,
                "the case tag, not the raw text, defines identity")

        // Same-case equality still holds.
        #expect(page == ChatAttachmentTarget.page(PageID(rawValue: "01HIDENTICALRAW")))

        // The selection helpers preserve row order.
        let ordered = ChatAttachmentTarget.pages([
            PageID(rawValue: "01HB"), PageID(rawValue: "01HA"),
        ])
        #expect(ordered == [.page(PageID(rawValue: "01HB")), .page(PageID(rawValue: "01HA"))])
        #expect(ChatAttachmentTarget.sources([]).isEmpty)
    }
}

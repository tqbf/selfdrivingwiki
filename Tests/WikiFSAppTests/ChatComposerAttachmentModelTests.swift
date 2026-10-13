#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Unit tests for the composer chip model, including the app-target half of
/// the typed-distinctness contract: the enum-level distinctness lives in
/// `ChatAttachmentTargetTests` (WikiFSTests); this suite asserts the chips
/// built through `ChatAttachment.init(target:store:)`, which is internal to
/// the WikiFS module.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatComposerAttachmentModelTests {

    private func makeModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let store = try GRDBWikiStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("composer-attach-\(UUID().uuidString).sqlite"))
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        return (WikiStoreModel(store: store), store)
    }

    @Test("a page and a source with identical raw text produce distinct chips")
    func identicalRawTextPageAndSourceProduceDistinctChips() throws {
        let (store, _) = try makeModel()
        let pageTarget = ChatAttachmentTarget.page(PageID(rawValue: "01HIDENTICALRAW"))
        let sourceTarget = ChatAttachmentTarget.source(SourceID(rawValue: "01HIDENTICALRAW"))

        let pageChip = ChatAttachment(target: pageTarget, store: store)
        let sourceChip = ChatAttachment(target: sourceTarget, store: store)

        #expect(pageChip != sourceChip,
                "kind:itemID identity must keep the namespaces apart at chip level")
        #expect(pageChip.id == "page:01HIDENTICALRAW")
        #expect(sourceChip.id == "source:01HIDENTICALRAW")
    }

    @Test("replace swaps the whole list rather than appending")
    func replaceReplacesRatherThanAppends() throws {
        let (store, _) = try makeModel()
        let model = ChatComposerAttachmentModel()
        model.add(ChatAttachment(target: .page(PageID(rawValue: "01HA")), store: store))
        model.add(ChatAttachment(target: .page(PageID(rawValue: "01HB")), store: store))
        #expect(model.attachments.count == 2)

        let replacement = [ChatAttachment(target: .source(SourceID(rawValue: "01HC")), store: store)]
        model.replace(with: replacement)

        #expect(model.attachments == replacement,
                "queued restore is a swap, not an append")
        #expect(model.attachments.count == 1)
    }

    @Test("applyTargets adds in order, resolves names, and dedupes")
    func applyTargetsAddsInOrderAndDedupes() throws {
        let (store, grdb) = try makeModel()
        let page = try grdb.createPage(title: "Ordered Page")
        // resolveAttachmentName reads the model's summaries cache — refresh
        // it so the typed adapter resolves the created page's title.
        store.reloadFromStore()
        let model = ChatComposerAttachmentModel()

        let targets: [ChatAttachmentTarget] = [
            .page(page.id),
            .source(SourceID(rawValue: "01HORDERSOURCE")),
            .page(page.id),
        ]
        model.applyTargets(targets, store: store)

        #expect(model.attachments.count == 2, "the repeated target dedupes")
        #expect(model.attachments[0].displayName == "Ordered Page",
                "the typed adapter resolves the display name like the drop path")
        #expect(model.attachments[0].kind == .page)
        #expect(model.attachments[1].kind == .source)
        #expect(model.attachments[1].itemID == "01HORDERSOURCE")
    }
}
#endif

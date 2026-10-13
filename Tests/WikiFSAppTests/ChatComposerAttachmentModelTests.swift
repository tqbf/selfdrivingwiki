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

    /// Counts post-commit `.chat` events on the fixture store's bus.
    @MainActor
    private final class MutationEventCounter {
        private(set) var updated = 0
        private var token: SubscriptionToken?

        func attach(to bus: WikiEventBus) {
            token = bus.subscribe(.chat) { [weak self] event in
                guard event.change == .updated else { return }
                self?.updated += 1
            }
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(4),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    @Test("a page, a source, and a chat with identical raw text produce distinct chips")
    func identicalRawTextTripleProducesDistinctChips() throws {
        let (store, _) = try makeModel()
        let raw = "01HIDENTICALRAW"
        let chips = [
            ChatAttachment(target: .page(PageID(rawValue: raw)), store: store),
            ChatAttachment(target: .source(SourceID(rawValue: raw)), store: store),
            ChatAttachment(target: .chat(ChatID(rawValue: raw)), store: store),
        ]
        #expect(chips.map(\.id) == ["page:\(raw)", "source:\(raw)", "chat:\(raw)"])
        #expect(Set(chips.map(\.id)).count == 3, "pairwise distinct identities")
    }

    @Test("bound mutations write through; a repeated bind + restore writes nothing")
    func bindWriteThroughAndRepeatedBindZeroWrite() async throws {
        let (model, grdb) = try makeModel()
        let chat = try grdb.createChat(kind: .edit, title: "")
        let counter = MutationEventCounter()
        counter.attach(to: model.eventBus!)
        let composerModel = ChatComposerAttachmentModel()

        // First mount: bind, restore (nonpersisting), arm, then a mutation.
        composerModel.bind(store: model, chatID: chat.id)
        composerModel.restoreFromStore()
        composerModel.armPersistence()
        #expect(await waitUntil(timeout: .milliseconds(300)) { counter.updated == 0 },
                "the mount itself performs zero writes")

        let chip = ChatAttachment(target: .page(PageID(rawValue: "01HWRITE")), store: model)
        composerModel.add(chip)
        #expect(await waitUntil { counter.updated == 1 }, "exactly one event for one mutation")
        #expect(try grdb.chatAttachments(chatID: chat.id)
            == [.page(PageID(rawValue: "01HWRITE"))])

        // A repeat mount (bind + restore + arm) reads and writes nothing.
        composerModel.bind(store: model, chatID: chat.id)
        composerModel.restoreFromStore()
        composerModel.armPersistence()
        #expect(composerModel.attachments == [chip])
        #expect(await waitUntil(timeout: .milliseconds(300)) { counter.updated == 1 },
                "the repeat mount emitted no event")
        #expect(try grdb.chatAttachments(chatID: chat.id)
            == [.page(PageID(rawValue: "01HWRITE"))])
    }

    @Test("unbound and draft-surface models never persist")
    func unboundAndDraftNeverPersist() throws {
        let (store, grdb) = try makeModel()
        let chat = try grdb.createChat(kind: .edit, title: "")

        // Unbound: no bind call at all.
        let unbound = ChatComposerAttachmentModel()
        unbound.add(ChatAttachment(target: .page(PageID(rawValue: "01HU")), store: store))
        #expect(try grdb.chatAttachments(chatID: chat.id).isEmpty)

        // Draft surface: bound to a nil chat — never arms.
        let draft = ChatComposerAttachmentModel()
        draft.bind(store: store, chatID: nil)
        draft.restoreFromStore()
        draft.armPersistence()
        #expect(draft.isPersistenceArmed == false)
        draft.add(ChatAttachment(target: .page(PageID(rawValue: "01HV")), store: store))
        #expect(try grdb.chatAttachments(chatID: chat.id).isEmpty)
    }
}
#endif

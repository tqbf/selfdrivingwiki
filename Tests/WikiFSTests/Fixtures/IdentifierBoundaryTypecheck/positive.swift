import WikiFSCore
import WikiFSTypes

func acceptsCorrectIdentifierNamespaces(
    store: any WikiStore,
    pageID: PageID,
    sourceID: SourceID,
    chatID: ChatID
) throws {
    _ = try store.getPage(id: pageID)
    _ = try store.sourceContent(id: sourceID)
    _ = try store.getChat(id: chatID)
}

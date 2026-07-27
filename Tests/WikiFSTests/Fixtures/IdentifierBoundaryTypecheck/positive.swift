import WikiFSCore
import WikiFSTypes

func acceptsCorrectIdentifierNamespaces(
    store: any WikiStore,
    pageID: PageID,
    sourceID: SourceID,
    chatID: ChatID,
    sourceVersionID: SourceVersionID,
    concreteStore: GRDBWikiStore
) throws {
    _ = try store.getPage(id: pageID)
    _ = try store.sourceContent(id: sourceID)
    _ = try store.getChat(id: chatID)
    _ = try store.recordMarkdownExtraction(
        sourceID: sourceID,
        content: "# markdown",
        backend: .anthropic,
        sourceVersionID: sourceVersionID,
        note: nil,
        modelVersion: nil
    )
    try concreteStore.rollbackSourceContent(sourceID: sourceID, to: sourceVersionID)
}

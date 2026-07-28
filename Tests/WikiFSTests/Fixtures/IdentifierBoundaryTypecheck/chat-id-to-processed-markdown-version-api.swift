import WikiFSCore
import WikiFSTypes

func chatIDIsRejectedByProcessedMarkdownVersionAPI(store: any WikiStore, chatID: ChatID) throws {
    _ = try store.processedMarkdownVersion(id: chatID)
}

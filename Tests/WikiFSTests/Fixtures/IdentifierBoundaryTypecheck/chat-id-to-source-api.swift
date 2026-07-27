import WikiFSCore
import WikiFSTypes

func chatIDIsRejectedBySourceAPI(store: any WikiStore, chatID: ChatID) throws {
    _ = try store.sourceContent(id: chatID)
}

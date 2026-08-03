import WikiFSCore
import WikiFSTypes

func chatIDIsRejectedByPageAPI(store: any WikiStore, chatID: ChatID) throws {
    _ = try store.getPage(id: chatID)
}

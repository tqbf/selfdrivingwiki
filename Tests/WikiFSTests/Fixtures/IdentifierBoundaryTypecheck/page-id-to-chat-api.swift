import WikiFSCore
import WikiFSTypes

func pageIDIsRejectedByChatAPI(store: any WikiStore, pageID: PageID) throws {
    _ = try store.getChat(id: pageID)
}

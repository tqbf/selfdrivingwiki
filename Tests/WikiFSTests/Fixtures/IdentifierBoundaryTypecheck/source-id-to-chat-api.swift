import WikiFSCore
import WikiFSTypes

func sourceIDIsRejectedByChatAPI(store: any WikiStore, sourceID: SourceID) throws {
    _ = try store.getChat(id: sourceID)
}

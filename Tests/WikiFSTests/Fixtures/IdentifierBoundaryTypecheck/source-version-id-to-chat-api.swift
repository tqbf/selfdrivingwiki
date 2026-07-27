import WikiFSCore
import WikiFSTypes

func sourceVersionIDIsRejectedByChatAPI(store: any WikiStore, sourceVersionID: SourceVersionID) throws {
    _ = try store.getChat(id: sourceVersionID)
}

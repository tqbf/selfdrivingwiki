import WikiFSCore
import WikiFSTypes

func sourceVersionIDIsRejectedBySourceAPI(store: any WikiStore, sourceVersionID: SourceVersionID) throws {
    _ = try store.sourceContent(id: sourceVersionID)
}

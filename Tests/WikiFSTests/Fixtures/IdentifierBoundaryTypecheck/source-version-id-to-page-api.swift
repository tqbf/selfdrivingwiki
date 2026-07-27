import WikiFSCore
import WikiFSTypes

func sourceVersionIDIsRejectedByPageAPI(store: any WikiStore, sourceVersionID: SourceVersionID) throws {
    _ = try store.getPage(id: sourceVersionID)
}

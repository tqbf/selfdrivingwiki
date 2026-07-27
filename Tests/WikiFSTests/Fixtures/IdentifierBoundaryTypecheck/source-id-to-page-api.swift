import WikiFSCore
import WikiFSTypes

func sourceIDIsRejectedByPageAPI(store: any WikiStore, sourceID: SourceID) throws {
    _ = try store.getPage(id: sourceID)
}

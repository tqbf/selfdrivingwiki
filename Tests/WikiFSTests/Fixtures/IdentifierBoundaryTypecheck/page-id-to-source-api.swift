import WikiFSCore
import WikiFSTypes

func pageIDIsRejectedBySourceAPI(store: any WikiStore, pageID: PageID) throws {
    _ = try store.sourceContent(id: pageID)
}

import WikiFSCore
import WikiFSTypes

func pageIDIsRejectedByProcessedMarkdownVersionAPI(store: any WikiStore, pageID: PageID) throws {
    _ = try store.processedMarkdownVersion(id: pageID)
}

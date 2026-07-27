import WikiFSCore
import WikiFSTypes

func pageIDIsRejectedBySourceVersionAPI(store: GRDBWikiStore, sourceID: SourceID, pageID: PageID) throws {
    try store.rollbackSourceContent(sourceID: sourceID, to: pageID)
}

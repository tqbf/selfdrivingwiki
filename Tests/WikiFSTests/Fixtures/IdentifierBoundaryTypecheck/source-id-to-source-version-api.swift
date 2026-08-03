import WikiFSCore
import WikiFSTypes

func sourceIDIsRejectedBySourceVersionAPI(store: GRDBWikiStore, sourceID: SourceID) throws {
    try store.rollbackSourceContent(sourceID: sourceID, to: sourceID)
}

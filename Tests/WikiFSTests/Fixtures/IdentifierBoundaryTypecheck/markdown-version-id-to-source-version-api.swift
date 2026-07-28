import WikiFSCore
import WikiFSTypes

func markdownVersionIDIsRejectedBySourceVersionAPI(
    store: GRDBWikiStore,
    sourceID: SourceID,
    markdownVersionID: SourceMarkdownVersionID
) throws {
    try store.rollbackSourceContent(sourceID: sourceID, to: markdownVersionID)
}

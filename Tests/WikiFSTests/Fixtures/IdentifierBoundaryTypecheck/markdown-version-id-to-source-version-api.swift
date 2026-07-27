import WikiFSCore
import WikiFSTypes

func markdownVersionIDIsRejectedBySourceVersionAPI(
    store: GRDBWikiStore,
    sourceID: SourceID,
    markdownVersion: SourceMarkdownVersion
) throws {
    try store.rollbackSourceContent(sourceID: sourceID, to: markdownVersion.id)
}

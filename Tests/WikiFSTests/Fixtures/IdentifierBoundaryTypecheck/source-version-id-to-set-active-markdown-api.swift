import WikiFSCore
import WikiFSTypes

func sourceVersionIDIsRejectedBySetActiveMarkdownAPI(
    store: any WikiStore,
    sourceID: SourceID,
    sourceVersionID: SourceVersionID
) throws {
    try store.setActiveMarkdown(sourceID: sourceID, to: sourceVersionID)
}

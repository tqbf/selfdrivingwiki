import WikiFSCore
import WikiFSTypes

func sourceVersionIDIsRejectedByProcessedMarkdownVersionAPI(store: any WikiStore, sourceVersionID: SourceVersionID) throws {
    _ = try store.processedMarkdownVersion(id: sourceVersionID)
}

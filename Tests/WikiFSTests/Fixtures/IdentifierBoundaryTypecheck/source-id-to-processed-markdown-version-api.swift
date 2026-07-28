import WikiFSCore
import WikiFSTypes

func sourceIDIsRejectedByProcessedMarkdownVersionAPI(store: any WikiStore, sourceID: SourceID) throws {
    _ = try store.processedMarkdownVersion(id: sourceID)
}

import WikiFSCore
import WikiFSTypes

func acceptsCorrectIdentifierNamespaces(
    store: any WikiStore,
    pageID: PageID,
    sourceID: SourceID,
    chatID: ChatID,
    sourceVersionID: SourceVersionID,
    sourceMarkdownVersionID: SourceMarkdownVersionID,
    concreteStore: GRDBWikiStore
) throws {
    _ = try store.getPage(id: pageID)
    _ = try store.sourceContent(id: sourceID)
    _ = try store.getChat(id: chatID)
    _ = try store.processedMarkdownVersion(id: sourceMarkdownVersionID)
    _ = try store.recordMarkdownExtraction(
        sourceID: sourceID,
        content: "# markdown",
        backend: .anthropic,
        sourceVersionID: sourceVersionID,
        note: nil,
        modelVersion: nil
    )
    try store.setActiveMarkdown(sourceID: sourceID, to: sourceMarkdownVersionID)
    try concreteStore.rollbackSourceContent(sourceID: sourceID, to: sourceVersionID)
}

func acceptsCorrectExtractorRouteUsage(
    configuration: ExtractionConfig,
    registrations: [ActiveExtractorRegistration]
) {
    let pdf = ExtractorRouteID.canonicalPDF
    let html = ExtractorRouteID.canonicalHTML
    let future = try? ExtractorRouteID(normalizing: .html, mimeTypeString: "Application/XHTML+XML")
    let ordered: [ExtractorRouteID] = [pdf, html] + (future.map { [$0] } ?? [])
    let sortedRoutes = ordered.sorted()
    _ = configuration.extractorSelection(for: pdf)
    var mutableConfiguration = configuration
    mutableConfiguration.setExtractorSelection(nil, for: html)
    _ = ExtractorSelectionResolver.resolve(pdf, configuration: mutableConfiguration, activeRegistrations: registrations)
    _ = sortedRoutes
}

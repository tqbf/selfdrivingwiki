#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

@Suite struct BuiltInRendererRegistryTests {
    @Test("Every BuiltInRendererID has exactly one descriptor and one factory")
    @MainActor
    func builtInDescriptorAndFactoryExhaustiveness() throws {
        let descriptors = BuiltInRendererDescriptors.all
        let ids = descriptors.compactMap { descriptor -> BuiltInRendererID? in
            guard case let .builtIn(id) = descriptor.implementation else { return nil }
            return id
        }

        #expect(ids.sorted() == BuiltInRendererID.allCases.sorted())
        for id in BuiltInRendererID.allCases {
            #expect(ids.filter { $0 == id }.count == 1, "\(id.rawValue) must have one descriptor")
            #expect(BuiltInRendererFactoryMap.factory(for: id) != nil, "\(id.rawValue) must have one factory")
        }
        #expect(BuiltInRendererFactoryMap.factories.keys.sorted() == BuiltInRendererID.allCases.sorted())
    }

    @Test("Snapshot combines built-ins with injected installed descriptors")
    func snapshotCombinesBuiltInsAndInstalledInput() throws {
        let installed = try testInstalledDescriptor()
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            enabledInstalledDescriptors: [installed])

        #expect(snapshot.descriptors.contains(installed))
        #expect(snapshot.descriptors.count == BuiltInRendererID.allCases.count + 1)
    }

    @Test("Planner maps PDF bytes to the PDF built-in")
    func plannerMatchesPDF() throws {
        let source = fixtureSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4)
        let id = try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: source,
            boundedBytes: Data("%PDF".utf8),
            currentMarkdown: nil,
            origin: nil)
        #expect(id == .pdf)
    }

    @Test("Unextracted PDF defaults rendered and carries its quote anchor to the PDF factory")
    @MainActor
    func unextractedPDFDefaultKeepsQuoteAnchorReachable() throws {
        let source = fixtureSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4)
        let descriptor = try #require(try SourceRendererPresentationPlanner()
            .matchingDescriptors(for: source, boundedBytes: Data("%PDF".utf8), currentMarkdown: nil, origin: nil)
            .first)
        let state = RendererPresentationState.defaultState(
            sourceID: source.id,
            matchingRenderer: descriptor.reference,
            hasPresentableSource: SourceRendererPresentationPlanner.hasPresentableSource(
                for: source,
                currentMarkdown: nil),
            persistedSelection: nil)
        let inputs = BuiltInRendererFactoryInputs(
            sourceBytes: Data("%PDF".utf8),
            pdfQuote: "a retained quote",
            htmlSource: nil,
            mermaidMarkdown: nil,
            mediaTarget: nil,
            selection: nil,
            store: WikiStoreModel(store: try GRDBWikiStore(
                databaseURL: URL.temporaryDirectory.appending(path: "renderer-quote-\(UUID().uuidString).sqlite"))),
            readerZoom: .constant(1))

        #expect(state.selection == .rendered)
        #expect(state.pinnedRenderer == descriptor.reference)
        #expect(inputs.pdfQuote == "a retained quote")
        #expect(BuiltInRendererFactoryMap.makeView(for: descriptor, inputs: inputs) != nil)
    }

    @Test(arguments: [
        ("markdown", fixtureSource(filename: "note.md", ext: "md", mimeType: MimeType.markdown, byteSize: 5), "# Note"),
        ("plain text", fixtureSource(filename: "note.txt", ext: "txt", mimeType: "text/plain", byteSize: 5), "hello"),
        ("media transcript", fixtureSource(filename: "video", ext: "", mimeType: "video/youtube", byteSize: 0), "Transcript")
    ])
    func presentableSourceKindsDefaultToSource(
        _: String,
        source: SourceSummary,
        markdown: String
    ) {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        let state = RendererPresentationState.defaultState(
            sourceID: source.id,
            matchingRenderer: pdf,
            hasPresentableSource: SourceRendererPresentationPlanner.hasPresentableSource(
                for: source,
                currentMarkdown: markdown),
            persistedSelection: nil)

        #expect(state.selection == .source)
        #expect(state.pinnedRenderer == nil)
    }

    @Test("Planner maps HTML bytes to the HTML built-in")
    func plannerMatchesHTML() throws {
        let source = fixtureSource(filename: "page.html", ext: "html", mimeType: MimeType.html, byteSize: 14)
        let id = try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: source,
            boundedBytes: Data("<h1>Hello</h1>".utf8),
            currentMarkdown: nil,
            origin: nil)
        #expect(id == .html)
    }

    @Test("HTML extraction classification does not depend on a loaded byte snapshot")
    func htmlExtractionClassificationSurvivesNilBytes() {
        let source = fixtureSource(filename: "page.html", ext: "html", mimeType: MimeType.html, byteSize: 14)
        #expect(SourceRendererPresentationPlanner.isHTMLSource(source))
        #expect(SourceRendererPresentationPlanner.htmlSourceString(for: source, bytes: nil) == nil)
    }

    @Test("Planner maps Mermaid extension/content to the Mermaid built-in")
    func plannerMatchesMermaid() throws {
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: nil, byteSize: 12)
        let id = try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: source,
            boundedBytes: Data("flowchart LR".utf8),
            currentMarkdown: "flowchart LR",
            origin: nil)
        #expect(id == .mermaid)
    }

    @Test("Characterization: NULL-MIME standalone Mermaid uses Source markdown presentation")
    func nullMIMEStandaloneMermaidUsesSourceMarkdownPresentation() {
        let source = fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: nil, byteSize: 12)

        #expect(SourceRendererPresentationPlanner.usesMarkdownSourcePresentation(
            for: source,
            currentMarkdown: nil))
    }

    @Test("Planner maps media origin to the Media built-in")
    func plannerMatchesMediaOrigin() throws {
        let source = fixtureSource(filename: "video.url", ext: "", mimeType: "video/youtube", byteSize: 0)
        let id = try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: source,
            boundedBytes: nil,
            currentMarkdown: nil,
            origin: fixtureOrigin(provider: .youtube, plan: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", externalIdentity: "dQw4w9WgXcQ"))
        #expect(id == .media)
    }

    @Test("Media without a transcript retains its dynamic Source empty state")
    func mediaWithoutTranscriptUsesDynamicSourceEmptyState() {
        let source = fixtureSource(filename: "video", ext: "", mimeType: "video/youtube", byteSize: 0)
        let origin = fixtureOrigin(provider: .youtube, plan: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", externalIdentity: "dQw4w9WgXcQ")
        let presentation = SourceRendererPresentationPlanner.emptyMediaPresentation(
            for: source,
            currentMarkdown: nil,
            origin: origin)
        #expect(presentation?.label == "No Video Transcript")
        #expect(presentation?.description.contains("no captions") == true)
    }

    @Test("An unsupported built-in factory result remains an explicit host fallback")
    @MainActor
    func unsupportedFactoryReturnsNilForHostFallback() throws {
        let descriptor = try testInstalledDescriptor()
        let inputs = BuiltInRendererFactoryInputs(
            sourceBytes: nil,
            pdfQuote: nil,
            htmlSource: nil,
            mermaidMarkdown: nil,
            mediaTarget: nil,
            selection: nil,
            store: WikiStoreModel(store: try GRDBWikiStore(
                databaseURL: URL.temporaryDirectory.appending(path: "renderer-factory-\(UUID().uuidString).sqlite"))),
            readerZoom: .constant(1))
        #expect(BuiltInRendererFactoryMap.makeView(for: descriptor, inputs: inputs) == nil)
    }

    @Test("Planner preserves Source fallback for media origins missing renderable identity or plan")
    func plannerRejectsMalformedMediaOrigins() throws {
        let youtube = fixtureSource(filename: "video.url", ext: "", mimeType: "video/youtube", byteSize: 0)
        let youtubeWithRawVideoMIME = fixtureSource(filename: "video.url", ext: "", mimeType: "video/mp4", byteSize: 0)
        let applePodcast = fixtureSource(filename: "episode.md", ext: "md", mimeType: MimeType.markdown, byteSize: 0)
        let applePodcastWithRawAudioMIME = fixtureSource(filename: "episode.mp3", ext: "mp3", mimeType: "audio/mpeg", byteSize: 0)
        let remoteMedia = fixtureSource(filename: "clip.mp4", ext: "mp4", mimeType: "video/mp4", byteSize: 0)

        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: youtube,
            boundedBytes: nil,
            currentMarkdown: nil,
            origin: fixtureOrigin(provider: .youtube, plan: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", externalIdentity: nil)) == nil)
        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: youtubeWithRawVideoMIME,
            boundedBytes: nil,
            currentMarkdown: nil,
            origin: fixtureOrigin(provider: .youtube, plan: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", externalIdentity: nil)) == nil)
        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: applePodcast,
            boundedBytes: nil,
            currentMarkdown: nil,
            origin: fixtureOrigin(provider: .applePodcast, plan: nil, externalIdentity: nil)) == nil)
        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: applePodcast,
            boundedBytes: nil,
            currentMarkdown: nil,
            origin: fixtureOrigin(provider: .applePodcast, plan: "https://example.com/show", externalIdentity: nil)) == nil)
        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: applePodcastWithRawAudioMIME,
            boundedBytes: nil,
            currentMarkdown: nil,
            origin: fixtureOrigin(provider: .applePodcast, plan: "https://example.com/show", externalIdentity: nil)) == nil)
        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(
            for: remoteMedia,
            boundedBytes: nil,
            currentMarkdown: nil,
            origin: fixtureOrigin(provider: .remoteMedia, plan: "https://example.com/clip.mp4", externalIdentity: nil)) == nil)
    }

    @Test("Source fallback stays outside matching for plain text, unknown, and missing content")
    func sourceFallbackIsOutsideRegistryMatching() throws {
        let plain = fixtureSource(filename: "note.txt", ext: "txt", mimeType: "text/plain", byteSize: 5)
        let unknown = fixtureSource(filename: "blob.bin", ext: "bin", mimeType: nil, byteSize: 5)
        let missing = fixtureSource(filename: "empty", ext: "", mimeType: nil, byteSize: 0)

        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(for: plain, boundedBytes: Data("hello".utf8), currentMarkdown: "hello", origin: nil) == nil)
        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(for: unknown, boundedBytes: Data([0, 1, 2]), currentMarkdown: nil, origin: nil) == nil)
        #expect(try SourceRendererPresentationPlanner.plannedBuiltInRenderer(for: missing, boundedBytes: nil, currentMarkdown: nil, origin: nil) == nil)
    }

    @Test("Characterization: PDF with markdown keeps Reader/PDF/Split tabs")
    func characterizesPDFWithMarkdown() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4),
            boundedBytes: Data("%PDF".utf8),
            currentMarkdown: "# Paper",
            hasProcessedMarkdown: true,
            origin: nil)
        #expect(result.contentArea == .tabbed)
        #expect(result.tabs == [.reader, .pdf, .split])
    }

    @Test("Characterization: PDF without markdown renders PDF only")
    func characterizesPDFWithoutMarkdown() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4),
            boundedBytes: Data("%PDF".utf8),
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.contentArea == .pdfOnly)
        #expect(result.tabs == [])
    }

    @Test("Characterization: HTML with markdown keeps Reader/HTML/Split tabs")
    func characterizesHTMLWithMarkdown() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "page.html", ext: "html", mimeType: MimeType.html, byteSize: 14),
            boundedBytes: Data("<h1>Hello</h1>".utf8),
            currentMarkdown: "# Hello",
            hasProcessedMarkdown: true,
            origin: nil)
        #expect(result.contentArea == .tabbed)
        #expect(result.tabs == [.reader, .html, .split])
    }

    @Test("Characterization: HTML without markdown renders HTML only")
    func characterizesHTMLWithoutMarkdown() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "page.html", ext: "html", mimeType: MimeType.html, byteSize: 14),
            boundedBytes: Data("<h1>Hello</h1>".utf8),
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.contentArea == .tabbed)
        #expect(result.tabs == [.html])
    }

    @Test("Characterization: Mermaid keeps Reader/Rendered/Split tabs")
    func characterizesMermaid() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "diagram.mmd", ext: "mmd", mimeType: nil, byteSize: 12),
            boundedBytes: Data("flowchart LR".utf8),
            currentMarkdown: "flowchart LR",
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.contentArea == .tabbed)
        #expect(result.tabs == [.reader, .rendered, .split])
    }

    @Test("Characterization: media with transcript keeps Reader/Media/Split tabs")
    func characterizesMediaWithTranscript() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "video", ext: "", mimeType: "video/youtube", byteSize: 0),
            boundedBytes: nil,
            currentMarkdown: "Transcript",
            hasProcessedMarkdown: true,
            origin: fixtureOrigin(provider: .youtube, plan: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", externalIdentity: "dQw4w9WgXcQ"))
        #expect(result.contentArea == .tabbed)
        #expect(result.tabs == [.reader, .media, .split])
    }

    @Test("Characterization: malformed media metadata keeps fallback with no Media tab")
    func characterizesMalformedMediaMetadataFallback() {
        let youtubeResult = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "video", ext: "", mimeType: "video/youtube", byteSize: 0),
            boundedBytes: nil,
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: fixtureOrigin(provider: .youtube, plan: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", externalIdentity: nil))
        let podcastResult = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "episode.md", ext: "md", mimeType: MimeType.markdown, byteSize: 0),
            boundedBytes: nil,
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: fixtureOrigin(provider: .applePodcast, plan: nil, externalIdentity: nil))

        #expect(youtubeResult.contentArea == .binaryFallback)
        #expect(youtubeResult.tabs == [])
        #expect(podcastResult.contentArea == .markdown)
        #expect(podcastResult.tabs == [])
    }

    @Test("Characterization: plain text uses markdown content area with no tabs")
    func characterizesPlainText() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "note.txt", ext: "txt", mimeType: "text/plain", byteSize: 5),
            boundedBytes: Data("hello".utf8),
            currentMarkdown: "hello",
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.contentArea == .markdown)
        #expect(result.tabs == [])
    }

    @Test("Characterization: unknown byteful content uses binary fallback")
    func characterizesUnknownContent() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "blob.bin", ext: "bin", mimeType: nil, byteSize: 3),
            boundedBytes: Data([0, 1, 2]),
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.contentArea == .binaryFallback)
        #expect(result.tabs == [])
    }

    @Test("Characterization: missing content uses binary fallback")
    func characterizesMissingContent() {
        let result = SourceDetailPresentationCharacterization.characterize(
            source: fixtureSource(filename: "empty", ext: "", mimeType: nil, byteSize: 0),
            boundedBytes: nil,
            currentMarkdown: nil,
            hasProcessedMarkdown: false,
            origin: nil)
        #expect(result.contentArea == .binaryFallback)
        #expect(result.tabs == [])
    }
}

private func fixtureSource(
    filename: String,
    ext: String,
    mimeType: String?,
    byteSize: Int
) -> SourceSummary {
    SourceSummary(
        id: SourceID(rawValue: "01J00000000000000000000000"),
        filename: filename,
        ext: ext,
        mimeType: mimeType,
        byteSize: byteSize,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        version: 1)
}

private func fixtureOrigin(
    provider: SourceProvider,
    plan: String?,
    externalIdentity: String?
) -> SourceOrigin {
    SourceOrigin(
        versionID: SourceVersionID(rawValue: "01J00000000000000000000001"),
        agentName: provider.rawValue,
        agentKind: "software",
        activityKind: "fetch",
        plan: plan,
        externalRef: plan,
        externalIdentity: externalIdentity,
        fetchedAt: Date(timeIntervalSince1970: 0))
}

private func testInstalledDescriptor() throws -> RendererDescriptor {
    let packageID = try RendererPackageID(validating: "org.example.installed")
    let version = try RendererPackageVersion(validating: "1.0.0")
    let registrationID = try RendererRegistrationID(validating: "installed")
    let entryPoint = RendererAsset(
        path: try .init(validating: "index.html"),
        digest: try RendererSHA256Digest(bytes: Array(repeating: 0, count: RendererSHA256Digest.byteCount)))
    return try RendererDescriptor(
        reference: RendererReference(packageID: packageID, version: version, registrationID: registrationID),
        displayName: "Installed",
        implementation: .webPackage(.init(path: entryPoint.path)),
        matchers: [.normalizedMIME(try .init(validating: MimeType.pdf))],
        presentations: [.web],
        approvedAssets: [entryPoint],
        capabilities: [.inputRead],
        sizeLimits: try .init(maximumInputByteCount: 1, maximumDecodedByteCount: 1),
        linkPolicy: .none,
        accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
        compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
        priority: 1)
}
#endif

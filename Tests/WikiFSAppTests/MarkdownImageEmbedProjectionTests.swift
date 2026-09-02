#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

struct MarkdownImageTargetProjectionTests {
    /// Installed JSON Canvas renderer package reference (reviewed). JSON Canvas
    /// is a Web package only now; these image-projection tests use the package
    /// descriptor as the claimed renderer.
    private static func jsonCanvasInstalledDescriptor() throws -> RendererDescriptor {
        let entry = try RendererRelativePath(validating: "index.html")
        return try RendererDescriptor(
            reference: .init(
                packageID: try RendererPackageID(validating: "org.selfdrivingwiki.json-canvas-readonly"),
                version: try RendererPackageVersion(validating: "1.0.0"),
                registrationID: try RendererRegistrationID(validating: "json-canvas")),
            displayName: "JSON Canvas",
            implementation: .webPackage(.init(path: entry)),
            matchers: [
                .normalizedMIME(try .init(validating: "application/json")),
                .extensionFallback(try .init(validating: "canvas")),
            ],
            presentations: [.web],
            supportedEmbeddingRoles: [.inlineContent, .disclosureRow],
            hasExplicitEmbeddingRoles: true,
            approvedAssets: [RendererAsset(path: entry, digest: try .init(hex: "aa0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0a"))],
            capabilities: [.inputRead, .externalLink, .hostNavigation],
            hostNavigation: try .init(allowedTargetKinds: [.page, .source, .namedContent]),
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .userActivatedExternal,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 110)
    }

    @Test("an exact sibling target projects pinned image facts")
    func exactSiblingTargetProjectsPinnedImageFacts() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = try Self.jsonCanvasInstalledDescriptor()
        let targets = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": source],
            siblingSourceIDs: ["images/board.canvas": source.sourceID],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [], enabledInstalledDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])

        guard case let .renderer(reference, pinnedSource) = targets["images/board.canvas"] else {
            Issue.record("expected the exact sibling path to select an inline renderer")
            return
        }
        #expect(reference == descriptor.reference)
        #expect(pinnedSource.sourceID == source.sourceID)
        #expect(pinnedSource.sourceVersionID == source.sourceVersionID)
        #expect(pinnedSource.mimeType == source.mimeType)
        #expect(pinnedSource.bytes == Self.jsonCanvasBytes)
        #expect(pinnedSource.digest == RendererSHA256.digest(Self.jsonCanvasBytes))
    }

    @Test("external unresolved and nonexact paths stay ordinary")
    func untrustedPathsStayOrdinary() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = try Self.jsonCanvasInstalledDescriptor()
        let targets = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": source],
            siblingSourceIDs: ["images/board.canvas": source.sourceID],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [], enabledInstalledDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])

        for target in [
            "https://example.com/board.canvas",
            "data:application/json;base64,e30=",
            "wiki-blob://source/01HUNTRUSTED",
            "images/../images/board.canvas",
            "images/missing.canvas",
        ] {
            #expect(targets[target] == nil)
        }
    }

    @Test("descriptor capability MIME and size failures stay ordinary")
    func failedEligibilityFactsStayOrdinary() throws {
        let descriptor = try Self.jsonCanvasInstalledDescriptor()
        let registry = try RendererRegistrySnapshot(builtInDescriptors: [], enabledInstalledDescriptors: [descriptor])
        let validSource = try imageSource(bytes: Self.jsonCanvasBytes)
        let siblingIDs = ["images/board.canvas": validSource.sourceID]
        let unclaimed = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": validSource],
            siblingSourceIDs: siblingIDs,
            registry: try RendererRegistrySnapshot(builtInDescriptors: []),
            inlineCapableReferences: [])
        let unsupportedFactory = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": validSource],
            siblingSourceIDs: siblingIDs,
            registry: registry,
            inlineCapableReferences: [])
        let wrongMIME = try imageSource(
            mimeType: "image/png",
            bytes: Self.jsonCanvasBytes)
        let oversized = try imageSource(
            bytes: Data(repeating: 0, count: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1))
        let mimeFailure = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": wrongMIME],
            siblingSourceIDs: siblingIDs,
            registry: registry,
            inlineCapableReferences: [descriptor.reference])
        let sizeFailure = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": oversized],
            siblingSourceIDs: siblingIDs,
            registry: registry,
            inlineCapableReferences: [descriptor.reference])
        let blobTarget = ResolvedMarkdownImageTarget.blob(validSource.sourceID)

        #expect(unclaimed["images/board.canvas"] == blobTarget)
        #expect(unsupportedFactory["images/board.canvas"] == blobTarget)
        #expect(mimeFailure["images/board.canvas"] == blobTarget)
        #expect(sizeFailure["images/board.canvas"] == blobTarget)
    }

    @Test("claimed images stay inline and preserve escaped fallback alt text")
    func claimedImagesStayInlineWithReadableFallback() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = try Self.jsonCanvasInstalledDescriptor()
        let targets = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": source],
            siblingSourceIDs: ["images/board.canvas": source.sourceID],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [], enabledInstalledDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])
        let prepared = ReaderMarkdown.preparedDocument("![System <&>](images/board.canvas)")
        let projection = ResolvedDocumentProjection(markdownImages: targets)
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: projection,
            options: .disabled)

        #expect(html.contains("sdw-inline-renderer"))
        #expect(html.contains("data-renderer-role=\"inlineContent\""))
        #expect(html.contains("System &lt;&amp;&gt;"))
        #expect(html.contains(#"<a href="wiki-blob://source/01HIMAGEPROJECTION0000000001">System &lt;&amp;&gt;</a>"#))
        #expect(!html.contains("<img"))
        #expect(!html.contains("sdw-renderer-card__row"))
        #expect(!html.contains("sdw-renderer-card__disclosure"))
        #expect(!html.contains("renderer-action://open"))
        #expect(!html.contains("data-renderer-admitted=\"true\""))
    }

    @Test("typed source embeds select a role-compatible structurally validated renderer")
    func typedSourceEmbedsSelectInlineRenderer() throws {
        let source = try imageSource(bytes: Self.excalidrawBytes)
        let descriptor = try excalidrawDescriptor(embeddingRoles: [.inlineContent, .disclosureRow])
        let plans = try DocumentSourceRendererProjection.build(
            sources: [source.sourceID: source],
            displayNames: [source.sourceID: "Excalidraw Architecture"],
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])

        let plan = try #require(plans[source.sourceID])
        #expect(plan.embeddingRole == .inlineContent)
        #expect(plan.rendererReference == descriptor.reference)
        #expect(plan.input == .source(source))
        #expect(plan.displayTitle == "Excalidraw Architecture")
        #expect(plan.activationMetadata != nil)
    }

    @Test("typed source renderer eligibility fails closed")
    func typedSourceRendererEligibilityFailsClosed() throws {
        let source = try imageSource(bytes: Self.excalidrawBytes)
        let inline = try excalidrawDescriptor(embeddingRoles: [.inlineContent])
        let rowOnly = try excalidrawDescriptor(embeddingRoles: [.disclosureRow])
        let malformed = try imageSource(bytes: Data(#"{"type":"other","version":2,"elements":[]}"#.utf8))

        let rowDenied = try DocumentSourceRendererProjection.build(
            sources: [source.sourceID: source],
            displayNames: [:],
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [rowOnly]),
            inlineCapableReferences: [rowOnly.reference])
        let factoryDenied = try DocumentSourceRendererProjection.build(
            sources: [source.sourceID: source],
            displayNames: [:],
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [inline]),
            inlineCapableReferences: [])
        let artifactDenied = try DocumentSourceRendererProjection.build(
            sources: [malformed.sourceID: malformed],
            displayNames: [:],
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [inline]),
            inlineCapableReferences: [inline.reference])

        #expect(rowDenied.isEmpty)
        #expect(factoryDenied.isEmpty)
        #expect(artifactDenied.isEmpty)
    }

    @Test("source renderer metadata prefilter requires inline MIME support and a factory")
    func sourceRendererMetadataPrefilterIsFailClosed() throws {
        let inline = try excalidrawDescriptor(embeddingRoles: [.inlineContent])
        let rowOnly = try excalidrawDescriptor(embeddingRoles: [.disclosureRow])
        let incompatible = try excalidrawDescriptor(
            embeddingRoles: [.inlineContent],
            minimumProtocolRevision: 2)
        let jsonMIME = "application/json"

        #expect(DocumentSourceRendererProjection.hasEligibleRenderer(
            mimeType: jsonMIME,
            fileExtension: nil,
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [inline]),
            inlineCapableReferences: [inline.reference]))
        #expect(!DocumentSourceRendererProjection.hasEligibleRenderer(
            mimeType: jsonMIME,
            fileExtension: nil,
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [rowOnly]),
            inlineCapableReferences: [rowOnly.reference]))
        #expect(!DocumentSourceRendererProjection.hasEligibleRenderer(
            mimeType: jsonMIME,
            fileExtension: nil,
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [inline]),
            inlineCapableReferences: []))
        #expect(!DocumentSourceRendererProjection.hasEligibleRenderer(
            mimeType: "image/png",
            fileExtension: nil,
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [inline]),
            inlineCapableReferences: [inline.reference]))
        #expect(!DocumentSourceRendererProjection.hasEligibleRenderer(
            mimeType: jsonMIME,
            fileExtension: nil,
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [incompatible]),
            inlineCapableReferences: [incompatible.reference]))
        // The extension fallback tier: a NULL-MIME row matches an
        // extension-fallback claim, and nothing matches when both are absent.
        let extensionBacked = try excalidrawDescriptor(
            embeddingRoles: [.inlineContent],
            matchers: [.extensionFallback(try .init(validating: "mmd"))])
        #expect(DocumentSourceRendererProjection.hasEligibleRenderer(
            mimeType: nil,
            fileExtension: "mmd",
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [extensionBacked]),
            inlineCapableReferences: [extensionBacked.reference]))
        #expect(!DocumentSourceRendererProjection.hasEligibleRenderer(
            mimeType: nil,
            fileExtension: nil,
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [extensionBacked]),
            inlineCapableReferences: [extensionBacked.reference]))
        #expect(!DocumentSourceRendererProjection.hasEligibleRenderer(
            mimeType: nil,
            fileExtension: "txt",
            registry: try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [extensionBacked]),
            inlineCapableReferences: [extensionBacked.reference]))
    }

    @Test("page canonical source image path uses typed renderer DOM output")
    @MainActor
    func pageCanonicalSourcePathUsesTypedRendererDOMOutput() throws {
        let store = try GRDBWikiStore(databaseURL: temporaryDatabaseURL())
        let bytes = Data(##"{"type":"excalidraw","version":2,"elements":[{"type":"rectangle","x":0,"y":0,"width":80,"height":40,"angle":0,"strokeColor":"#112233","backgroundColor":"#ffffff","strokeWidth":2,"opacity":100,"roundness":null,"isDeleted":false}]}"##.utf8)
        let source = try store.addSource(
            filename: "architecture.json",
            data: bytes,
            mimeType: "application/json")
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()
        let context = WikiRenderContext.build(from: model)
        let canonicalPath = "sources/by-id/\(source.id.rawValue).json"

        #expect(WikiReaderRep.Coordinator.markdownImageSourceMap(
            markdown: "![Drawing](\(canonicalPath))",
            currentSelection: .page(PageID(rawValue: "01HPAGECANONICALIMAGE000001")),
            context: context,
            sources: model.sources,
            bookmarkNodes: model.bookmarkNodes) == [canonicalPath: source.id])
        #expect(WikiReaderRep.Coordinator.markdownImageSourceMap(
            markdown: "![Wrong](sources/by-id/\(source.id.rawValue).png)",
            currentSelection: .page(PageID(rawValue: "01HPAGECANONICALIMAGE000001")),
            context: context,
            sources: model.sources,
            bookmarkNodes: model.bookmarkNodes) == nil)

        let descriptor = try excalidrawDescriptor(
            reference: .init(
                packageID: PackageFenceTestSupport.installedPackageID,
                version: PackageFenceTestSupport.installedPackageVersion,
                registrationID: PackageFenceTestSupport.installedRegistrationID),
            embeddingRoles: [.inlineContent])
        for authoredPath in [canonicalPath, "../../\(canonicalPath)"] {
            let markdown = "![Excalidraw architecture](\(authoredPath))"
            let sourceMap = try #require(WikiReaderRep.Coordinator.markdownImageSourceMap(
                markdown: markdown,
                currentSelection: .page(PageID(rawValue: "01HPAGECANONICALIMAGE000001")),
                context: context,
                sources: model.sources,
                bookmarkNodes: model.bookmarkNodes))
            let targets = WikiReaderRep.Coordinator.markdownImageTargets(
                siblingSourceMap: sourceMap,
                store: store,
                installedDescriptors: [descriptor])
            let prepared = ReaderMarkdown.preparedDocument(markdown)
            let html = MarkdownHTMLRenderer.render(
                prepared,
                projection: .init(markdownImages: targets),
                options: .disabled)

            #expect(html.contains("class=\"sdw-inline-renderer\""))
            #expect(html.contains("data-renderer-reference=\"org.selfdrivingwiki.excalidraw-readonly/1.0.5/excalidraw\""))
            #expect(!html.contains("<img src=\"\(authoredPath)\""))
            #expect(!html.contains("data-renderer-admitted=\"true\""))
        }
    }

    @Test("File Provider source paths resolve on demand without a global path map")
    func fileProviderSourcePathsResolveOnDemand() {
        let sourceID = SourceID(rawValue: "01HIMAGEPROJECTION0000000001")
        let source = SourceSummary(
            id: sourceID,
            filename: "architecture.json",
            ext: "json",
            mimeType: "application/json",
            byteSize: 100,
            createdAt: .distantPast,
            updatedAt: .distantPast,
            version: 1,
            displayName: "Excalidraw Architecture")
        let folderID = BookmarkID(rawValue: "01HBOOKMARKFOLDER0000000001")
        let rootRefID = BookmarkID(rawValue: "01HBOOKMARKROOTREF000000001")
        let nestedRefID = BookmarkID(rawValue: "01HBOOKMARKNESTED000000001")
        let bookmarks = [
            BookmarkNode(id: folderID, parentID: nil, position: 0, content: .folder(label: "Design")),
            BookmarkNode(id: rootRefID, parentID: nil, position: 1, content: .source(sourceID)),
            BookmarkNode(id: nestedRefID, parentID: folderID, position: 0, content: .source(sourceID)),
        ]
        let byID = "sources/by-id/\(sourceID.rawValue).json"
        let byName = "sources/by-name/\(FilenameEscaping.byNameSourceFilename(filename: source.effectiveName, ext: source.ext, sourceID: sourceID))"
        let encodedByName = byName.replacingOccurrences(of: " ", with: "%20")
        let rootBookmark = "bookmarks/Excalidraw Architecture"
        let nestedBookmark = "bookmarks/Design/Excalidraw Architecture"
        let pageRelativeByID = "../../\(byID)"
        let pageRelativeBookmark = "../\(nestedBookmark)"
        let markdown = [
            byID,
            byName,
            encodedByName,
            rootBookmark,
            nestedBookmark,
            pageRelativeByID,
            pageRelativeBookmark,
        ]
        .map { "![Drawing](<\($0)>)" }
        .joined(separator: "\n")

        let resolved = MarkdownImageSourcePathResolver.resolve(
            markdown: markdown,
            sources: [source],
            bookmarkNodes: bookmarks)

        #expect(resolved[byID] == sourceID)
        #expect(resolved[byName] == sourceID)
        #expect(resolved[encodedByName] == sourceID)
        #expect(resolved[rootBookmark] == sourceID)
        #expect(resolved[nestedBookmark] == sourceID)
        #expect(resolved[pageRelativeByID] == sourceID)
        #expect(resolved[pageRelativeBookmark] == sourceID)

        let rejectedPaths = [
            "/\(byID)",
            "folder/../\(byID)",
            "sources/../by-id/\(sourceID.rawValue).json",
            "../../other/\(byID)",
            "../../sources/by-id/../\(sourceID.rawValue).json",
            "../../\(byID)/",
        ]
        for rejectedPath in rejectedPaths {
            #expect(MarkdownImageSourcePathResolver.resolve(
                markdown: "![Wrong](<\(rejectedPath)>)",
                sources: [source],
                bookmarkNodes: bookmarks).isEmpty)
        }
        #expect(MarkdownImageSourcePathResolver.resolve(
            markdown: "![Wrong](sources/by-id/\(sourceID.rawValue).png)",
            sources: [source],
            bookmarkNodes: bookmarks).isEmpty)

        let duplicate = BookmarkNode(
            id: BookmarkID(rawValue: "01HBOOKMARKDUPLICATE0000001"),
            parentID: nil,
            position: 2,
            content: .source(sourceID))
        #expect(MarkdownImageSourcePathResolver.resolve(
            markdown: "![Ambiguous](<\(rootBookmark)>)",
            sources: [source],
            bookmarkNodes: bookmarks + [duplicate]).isEmpty)
    }

    @Test("source candidate selection excludes media unsupported MIME and page winners")
    @MainActor
    func sourceCandidateSelectionAvoidsUnneededContentReads() throws {
        let eligibleID = SourceID(rawValue: "01HCANDIDATEELIGIBLE00000001")
        let mermaidID = SourceID(rawValue: "01HCANDIDATEMERMAID00000001")
        let externalID = SourceID(rawValue: "01HCANDIDATEEXTERNAL0000001")
        let unsupportedID = SourceID(rawValue: "01HCANDIDATEUNSUPPORTED0001")
        let collisionID = SourceID(rawValue: "01HCANDIDATECOLLISION000001")
        let descriptor = try excalidrawDescriptor(embeddingRoles: [.inlineContent])
        let registry = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [descriptor])
        let context = WikiRenderContext(
            pageTitles: ["collision"],
            pageIDToName: [:],
            sourceNames: ["eligible", "mermaid", "external", "unsupported", "collision"],
            sourceIDToName: [
                eligibleID: "Eligible",
                mermaidID: "Mermaid",
                externalID: "External",
                unsupportedID: "Unsupported",
                collisionID: "Collision",
            ],
            chatTitles: [],
            chatIDToName: [:],
            uniqueLooseKeys: [],
            embedMap: [
                "eligible": .init(id: eligibleID, mimeType: "application/json", target: nil),
                "mermaid": .init(
                    id: mermaidID,
                    mimeType: "text/mermaid",
                    target: nil),
                "external": .init(
                    id: externalID,
                    mimeType: "video/youtube",
                    target: .init(kind: .iframe, url: "https://example.invalid/embed")),
                "unsupported": .init(id: unsupportedID, mimeType: "image/png", target: nil),
                "collision": .init(id: collisionID, mimeType: "application/json", target: nil),
            ],
            sourceDerivedChain: [:],
            siblingMaps: [:],
            blobScheme: "wiki-blob")
        let markdown = """
        ![[source:Eligible]]
        ![[source:Mermaid]]
        ![[source:External]]
        ![[source:Unsupported]]
        ![[Collision]]
        """

        let candidates = WikiReaderRep.Coordinator.sourceRendererCandidateIDs(
            markdown: markdown,
            context: context,
            registry: registry,
            inlineCapableReferences: [descriptor.reference])

        #expect(candidates == [eligibleID])
    }

    @Test("missing oversized and untrusted metadata never materialize image bytes")
    @MainActor
    func rejectedMetadataNeverReadsImageBytes() throws {
        let sourceID = SourceID(rawValue: "01HIMAGEPROJECTION0000000001")
        let version = SourceVersion(
            id: SourceVersionID(rawValue: "01HIMAGEVERSION00000000001"),
            sourceID: sourceID,
            parentID: nil,
            blobHash: "pinned-blob",
            mimeType: "application/json",
            activityID: nil,
            externalIdentity: nil,
            fetchedAt: .distantPast)
        let rejectedCounts: [Int?] = [
            nil,
            WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1,
        ]

        for byteCount in rejectedCounts {
            var readCalls = 0
            let source = try WikiReaderRep.Coordinator.pinnedImageSource(
                sourceID: sourceID,
                version: version,
                inputByteCount: { _ in byteCount },
                readBytes: { _ in
                    readCalls += 1
                    return Self.jsonCanvasBytes
                })
            #expect(source == nil)
            #expect(readCalls == 0)
        }

        var untrustedReadCalls = 0
        let untrustedSource = try WikiReaderRep.Coordinator.pinnedImageSource(
            sourceID: SourceID(rawValue: "01HUNTRUSTEDSOURCE000000001"),
            version: version,
            inputByteCount: { _ in Self.jsonCanvasBytes.count },
            readBytes: { _ in
                untrustedReadCalls += 1
                return Self.jsonCanvasBytes
            })
        #expect(untrustedSource == nil)
        #expect(untrustedReadCalls == 0)
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-image-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    private static let jsonCanvasBytes = Data(#"{"nodes":[],"edges":[]}"#.utf8)
    private static let excalidrawBytes = Data(#"{"type":"excalidraw","version":2,"elements":[]}"#.utf8)

    private func excalidrawDescriptor(
        reference: RendererReference? = nil,
        embeddingRoles: Set<RendererEmbeddingRole>,
        matchers: [RendererMatcher]? = nil,
        minimumProtocolRevision: Int = 1
    ) throws -> RendererDescriptor {
        let resolvedReference = reference ?? RendererReference(
            packageID: PackageFenceTestSupport.installedPackageID,
            version: PackageFenceTestSupport.installedPackageVersion,
            registrationID: PackageFenceTestSupport.installedRegistrationID)
        let entryAsset = RendererAsset(
            path: try RendererRelativePath(validating: "index.html"),
            digest: try RendererSHA256Digest(hex: String(repeating: "0", count: 64)))
        return try RendererDescriptor(
            reference: resolvedReference,
            displayName: "Excalidraw",
            implementation: .webPackage(RendererWebEntryPoint(
                path: try RendererRelativePath(validating: "index.html"))),
            matchers: matchers ?? [
                .normalizedMIME(try RendererMIMEType(validating: "application/json")),
                .boundedJSON(try RendererJSONConstraints(
                    properties: [
                        "type": .stringEquals("excalidraw"),
                        "version": .integerEquals(2),
                    ],
                    arrays: ["elements": .object])),
            ],
            presentations: [.web],
            supportedEmbeddingRoles: embeddingRoles,
            hasExplicitEmbeddingRoles: true,
            approvedAssets: [entryAsset],
            capabilities: [.inputRead],
            sizeLimits: try RendererSizeLimits(
                maximumInputByteCount: 48_000,
                maximumDecodedByteCount: 48_000),
            linkPolicy: .none,
            accessibility: .init(
                supportsVoiceOver: true,
                supportsKeyboardNavigation: true),
            compatibility: try RendererCompatibility(
                minimumProtocolRevision: minimumProtocolRevision,
                maximumProtocolRevision: minimumProtocolRevision),
            priority: 110)
    }

    private func imageSource(
        mimeType: String = "application/json",
        bytes: Data
    ) throws -> RendererEmbeddedContent.Source {
        try RendererEmbeddedContent.Source(
            sourceID: SourceID(rawValue: "01HIMAGEPROJECTION0000000001"),
            sourceVersionID: SourceVersionID(rawValue: "01HIMAGEVERSION00000000001"),
            mimeType: try RendererMIMEType(validating: mimeType),
            bytes: bytes)
    }
}
#endif

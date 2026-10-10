import Foundation
import FileProvider
import Testing
import WikiFSCore
import WikiFSLinks
@testable import WikiFS
@testable import WikiFSFileProvider

/// Projection-level tests for the byteless-source rule (#1375): a source with
/// `byte_size == 0` (fetched content — YouTube transcript, podcast, remote
/// media) must not project a zero-byte extension-less file. When its
/// `source_versions.external_identity` is a usable http(s) URL, the node in
/// the verbatim slot is an Apple `.webloc` URL shortcut (same item
/// identifier, `.webloc` extension, webloc-XML bytes); without a usable
/// identity the old zero-byte verbatim node stays (mount identity and link
/// targets never dangle). Covers enumeration (both views), single-item
/// resolution, content serving, link-map targets, and the Share node rule.
@Suite
struct ZeroByteSourceProjectionTests {

    private let originURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    /// The store owns the temp DB file; the URL is kept separately because the
    /// Projection reads the database through its own read-only connection.
    private func makeStore() throws -> (store: GRDBWikiStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-byteless-\(UUID().uuidString).sqlite")
        return (try GRDBWikiStore(databaseURL: url), url)
    }

    private func makeProjection(_ fixture: (store: GRDBWikiStore, url: URL)) -> Projection {
        Projection(
            wikiID: WikiID(rawValue: "byteless-\(UUID().uuidString)"),
            databaseURL: fixture.url)
    }

    private func bytelessProvenance(externalIdentity: String?) -> SourceProvenance {
        SourceProvenance(
            agentName: "youtube", activityKind: "fetch",
            plan: externalIdentity, externalRef: nil,
            externalIdentity: externalIdentity)
    }

    private func addBytelessSource(
        _ store: GRDBWikiStore, filename: String,
        mimeType: String?, externalIdentity: String?
    ) throws -> SourceSummary {
        try store.addBytelessSource(
            filename: filename, mimeType: mimeType,
            provenance: bytelessProvenance(externalIdentity: externalIdentity))
    }

    /// Test 1: byteless + head + `video/youtube` → [webloc shortcut, `.md`
    /// sibling] under BOTH views; the shortcut is non-empty and versioned
    /// with the webloc marker (so existing mounts refetch); no zero-byte node.
    @Test func bytelessWithHeadProjectsWeblocShortcutAndMarkdownSibling() throws {
        let fixture = try makeStore()
        let source = try addBytelessSource(
            fixture.store, filename: "Warp Talk", mimeType: MimeType.videoYouTube,
            externalIdentity: originURL)
        _ = try fixture.store.appendProcessedMarkdown(
            sourceID: source.id, content: "---\ntype: \"Source\"\n---\n\nTranscript.",
            origin: .extraction, note: nil)
        let projection = makeProjection(fixture)
        // Each view projects exactly this source's two nodes; the verbatim
        // slot holds the `.webloc` shortcut carrying the source's identifier.
        let views: [(container: NSFileProviderItemIdentifier,
                     makeID: (String) -> NSFileProviderItemIdentifier)] = [
                (Projection.Identity.sourcesByName, Projection.Identity.sourceByName),
                (Projection.Identity.sourcesByID, Projection.Identity.sourceByID),
            ]
        for view in views {
            let nodes = projection.children(of: view.container)
            #expect(nodes.count == 2, "expected [webloc, .md], got \(nodes.map(\.name))")
            let shortcut = try #require(nodes.first { !$0.name.hasSuffix(".md") })
            let sibling = try #require(nodes.first { $0.name.hasSuffix(".md") })
            #expect(shortcut.name.hasSuffix(".webloc"))
            #expect(shortcut.id == view.makeID(source.id.rawValue),
                "shortcut reuses the source's own item identifier")
            #expect(shortcut.size > 0, "no zero-byte node may survive")
            #expect(String(decoding: shortcut.contentVersion, as: UTF8.self)
                .contains(Projection.weblocVersionMarker),
                "contentVersion must move off the bare row version")
            #expect(sibling.size > 0)
        }
    }

    /// Test 2: byteless + no head + URL present → [webloc shortcut] only.
    @Test func bytelessWithoutHeadProjectsWeblocShortcutOnly() throws {
        let fixture = try makeStore()
        let source = try addBytelessSource(
            fixture.store, filename: "Remote Clip", mimeType: "video/mp4",
            externalIdentity: "https://example.com/clip.mp4")
        let projection = makeProjection(fixture)
        let nodes = projection.children(of: Projection.Identity.sourcesByName)
        #expect(nodes.count == 1, "expected [webloc] only, got \(nodes.map(\.name))")
        let node = try #require(nodes.first)
        #expect(node.id == Projection.Identity.sourceByName(source.id.rawValue),
            "the single node is this source's shortcut")
        #expect(node.name.hasSuffix(".webloc"))
        #expect(node.size > 0)
    }

    /// Test 3: byteless + no head + NO usable external identity (nil, or a
    /// provider-specific bare id) → the zero-byte verbatim node, unchanged
    /// (fallback preserved: mount identity and link targets never dangle).
    @Test func bytelessWithoutUsableIdentityKeepsVerbatimNode() throws {
        let fixture = try makeStore()
        let noIdentity = try addBytelessSource(
            fixture.store, filename: "No Origin", mimeType: MimeType.videoYouTube,
            externalIdentity: nil)
        let bareID = try addBytelessSource(
            fixture.store, filename: "Bare Video Id", mimeType: MimeType.videoYouTube,
            externalIdentity: "dQw4w9WgXcQ")
        let projection = makeProjection(fixture)
        let nodes = projection.children(of: Projection.Identity.sourcesByName)
        for source in [noIdentity, bareID] {
            let node = try #require(nodes.first {
                $0.id == Projection.Identity.sourceByName(source.id.rawValue)
            })
            #expect(!node.name.hasSuffix(".webloc"),
                "\(source.filename): no usable URL → no shortcut")
            #expect(node.size == 0, "fallback keeps the (zero-byte) verbatim node")
        }
    }

    /// Test 3b: the issue's REAL shape (#1375) — byteless + head +
    /// `video/youtube` + a BARE YouTube video id in `external_identity`
    /// (not a URL, so no `.webloc` is possible) → nodes == [md sibling]
    /// EXACTLY: the zero-byte verbatim node is dropped, and the retired
    /// verbatim identifier resolves to nothing (node + content nil) so
    /// single-item resolution matches enumeration.
    @Test func bytelessBareIdWithHeadDropsZeroByteVerbatimNode() throws {
        let fixture = try makeStore()
        let source = try addBytelessSource(
            fixture.store, filename: "Warp Talk", mimeType: MimeType.videoYouTube,
            externalIdentity: "tUPPVhBBcoM")
        _ = try fixture.store.appendProcessedMarkdown(
            sourceID: source.id, content: "---\ntype: \"Source\"\n---\n\nTranscript.",
            origin: .extraction, note: nil)
        let projection = makeProjection(fixture)
        let views: [(container: NSFileProviderItemIdentifier,
                     makeID: (String) -> NSFileProviderItemIdentifier)] = [
                (Projection.Identity.sourcesByName, Projection.Identity.sourceByName),
                (Projection.Identity.sourcesByID, Projection.Identity.sourceByID),
            ]
        for view in views {
            let sourceID = view.makeID(source.id.rawValue)
            let nodes = projection.children(of: view.container)
            #expect(nodes.count == 1, "expected [md sibling] ONLY, got \(nodes.map(\.name))")
            let node = try #require(nodes.first)
            #expect(node.name.hasSuffix(".md"), "only the sibling survives")
            #expect(!node.name.hasSuffix(".webloc"))
            #expect(node.size > 0, "no zero-byte node may survive")
            // The verbatim identifier is retired with its node: a stale
            // client fetch resolves to nothing, in metadata and content.
            #expect(projection.node(for: sourceID) == nil)
            #expect(projection.contents(for: sourceID) == nil)
        }
    }

    /// Webloc upgrade (#1375 follow-up): the issue's REAL shape — byteless +
    /// `video/youtube` + a BARE video id in `external_identity`, with the
    /// fetch activity carrying the full origin URL (`plan`, mirrored in
    /// `external_ref`) — resolves the origin from the ACTIVITY: the node
    /// list is [webloc shortcut, `.md` sibling] and the sibling frontmatter
    /// carries the activity's plan URL (the identity alone would never
    /// resolve).
    @Test func bytelessBareIdWithActivityPlanURLProjectsWeblocAndCarriesOrigin() throws {
        let fixture = try makeStore()
        let source = try fixture.store.addBytelessSource(
            filename: "Warp Talk", mimeType: MimeType.videoYouTube,
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: originURL, externalRef: originURL,
                externalIdentity: "tUPPVhBBcoM"))
        _ = try fixture.store.appendProcessedMarkdown(
            sourceID: source.id, content: "Transcript.", origin: .extraction, note: nil)
        let projection = makeProjection(fixture)
        let nodes = projection.children(of: Projection.Identity.sourcesByName)
        #expect(nodes.count == 2, "expected [webloc, .md], got \(nodes.map(\.name))")
        #expect(nodes.contains { $0.name.hasSuffix(".webloc") && $0.size > 0 })
        #expect(nodes.contains { $0.name.hasSuffix(".md") })
        // The sibling frontmatter carries the ACTIVITY's URL — the identity
        // is only the bare video id and resolves to nothing on its own.
        let content = String(
            decoding: projection.contents(
                for: Projection.Identity.sourceMarkdownByName(source.id.rawValue))
                ?? Data(),
            as: UTF8.self)
        #expect(content.contains("- resource: \"\(originURL)\""),
            "frontmatter must carry the activity's plan URL")
    }

    /// Test 4: source WITH bytes + head + non-text mime → [verbatim, sibling]
    /// — regression guard that the byteless rule leaves byteful sources alone.
    @Test func sourceWithBytesAndHeadKeepsVerbatimPlusSibling() throws {
        let fixture = try makeStore()
        let pdf = try fixture.store.addSource(
            filename: "doc.pdf", data: Data("%PDF-1.4 fake".utf8),
            mimeType: "application/pdf")
        _ = try fixture.store.appendProcessedMarkdown(
            sourceID: pdf.id, content: "# Extracted", origin: .extraction, note: nil)
        let projection = makeProjection(fixture)
        let nodes = projection.children(of: Projection.Identity.sourcesByName)
        #expect(nodes.count == 2)
        let verbatim = try #require(nodes.first { !$0.name.hasSuffix(".md") })
        let sibling = try #require(nodes.first { $0.name.hasSuffix(".md") })
        #expect(verbatim.name.hasSuffix(".pdf"))
        #expect(verbatim.size == pdf.byteSize)
        #expect(sibling.size > 0)
    }

    /// Test 5: served content for a byteless source's identifier (both views)
    /// is webloc XML whose URL is the stored external identity, and the byte
    /// count matches the node's reported size exactly (size==content, or `cat`
    /// truncates).
    @Test func weblocContentServesPropertyListMatchingIdentityAndSize() throws {
        let fixture = try makeStore()
        let source = try addBytelessSource(
            fixture.store, filename: "Warp Talk", mimeType: MimeType.videoYouTube,
            externalIdentity: originURL)
        let projection = makeProjection(fixture)
        let views: [(String) -> NSFileProviderItemIdentifier] = [
            Projection.Identity.sourceByName, Projection.Identity.sourceByID]
        for makeID in views {
            let id = makeID(source.id.rawValue)
            let node = try #require(projection.node(for: id))
            let data = try #require(projection.contents(for: id))
            #expect(node.size == data.count,
                "documentSize must equal served byte count exactly")
            let plist = try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: String])
            #expect(plist[Projection.weblocURLKey] == originURL)
            #expect(data == Projection.weblocData(for: URL(string: originURL)!))
        }
    }

    /// Test 6: the link-map target for a byteless no-head source points at
    /// the `.webloc` filename, so `[[wikilinks]]` rewritten in the by-name
    /// view still resolve against the projected tree.
    @Test func linkMapTargetForBytelessNoHeadSourceIsWeblocFilename() throws {
        let fixture = try makeStore()
        let source = try addBytelessSource(
            fixture.store, filename: "Remote Clip", mimeType: "video/mp4",
            externalIdentity: "https://example.com/clip.mp4")
        let body = "See [[source:\(source.id.rawValue)|the clip]]."
        let page = try fixture.store.createPage(title: "Citing Page")
        try fixture.store.updatePage(id: page.id, title: "Citing Page", body: body)
        try fixture.store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(body))
        let projection = makeProjection(fixture)
        let expectedName = FilenameEscaping.byNameSourceFilename(
            filename: source.filename, ext: Projection.weblocFileExtension,
            sourceID: source.id)
        // The mount actually projects a node with that name…
        let nodes = projection.children(of: Projection.Identity.sourcesByName)
        #expect(nodes.contains { $0.name == expectedName })
        // …and the rewritten page links to it (by-title content is rewritten
        // through the same `LinkMaps` the by-name view uses). Link
        // destinations are percent-encoded, so compare the encoded form.
        let content = String(
            decoding: projection.contents(
                for: Projection.Identity.pageByTitle(page.id.rawValue)) ?? Data(),
            as: UTF8.self)
        let encodedName = expectedName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? expectedName
        #expect(
            content.contains("sources/by-name/\(encodedName)")
                || content.contains("sources/by-name/\(expectedName)"),
            "link target must name the .webloc shortcut, got: \(content)")
    }

    /// Test 7: the Share node rule — head + non-text mime → the markdown
    /// sibling identifier; otherwise the raw node.
    @Test func shareRulePrefersMarkdownSiblingOnlyForHeadedNonTextSources() {
        #expect(SourceShareNodeChoice.forSource(
            hasProcessedHead: true, mimeType: MimeType.videoYouTube) == .markdownSibling)
        #expect(SourceShareNodeChoice.forSource(
            hasProcessedHead: true, mimeType: "application/pdf") == .markdownSibling)
        // Markdown-native: the verbatim file IS the markdown content.
        #expect(SourceShareNodeChoice.forSource(
            hasProcessedHead: true, mimeType: MimeType.markdown) == .rawNode)
        #expect(SourceShareNodeChoice.forSource(
            hasProcessedHead: true, mimeType: "text/plain") == .rawNode)
        // No head: the raw node (the .webloc shortcut for byteless sources).
        #expect(SourceShareNodeChoice.forSource(
            hasProcessedHead: false, mimeType: MimeType.videoYouTube) == .rawNode)
        #expect(SourceShareNodeChoice.forSource(
            hasProcessedHead: false, mimeType: nil) == .rawNode)
    }

    // MARK: - Sibling origin URL + honest sizing (#1375 follow-up)

    /// Change 2 regression pin: the sibling node's size equals the served
    /// byte count EXACTLY on BOTH views, on a fixture with producer metadata
    /// (non-trivial frontmatter). The pre-fix node sized from raw
    /// `head.content`, under-reporting by exactly the OKF frontmatter the
    /// render prepends; the cached render makes size == served bytes. The
    /// enumerated and single-item versions must also agree (same cache).
    @Test func siblingNodeSizeMatchesServedBytesExactlyOnBothViews() throws {
        let fixture = try makeStore()
        let source = try fixture.store.addSource(
            filename: "report.pdf", data: Data("%PDF-1.4 producer fixture".utf8),
            mimeType: "application/pdf",
            provenance: bytelessProvenance(externalIdentity: "https://example.com/report"))
        let head = try fixture.store.appendProcessedMarkdown(
            sourceID: source.id, content: "# Extracted with producer",
            origin: .extraction, note: nil, technique: "pdf2md v1.2")
        let projection = makeProjection(fixture)
        let views: [(container: NSFileProviderItemIdentifier,
                     makeID: (String) -> NSFileProviderItemIdentifier)] = [
                (Projection.Identity.sourcesByName, Projection.Identity.sourceMarkdownByName),
                (Projection.Identity.sourcesByID, Projection.Identity.sourceMarkdownByID),
            ]
        for view in views {
            let id = view.makeID(source.id.rawValue)
            let node = try #require(projection.node(for: id))
            let bytes = try #require(projection.contents(for: id))
            #expect(node.size == bytes.count,
                "documentSize must equal the served byte count exactly")
            // The OKF-wrapped render is strictly larger than the raw head —
            // the delta is the frontmatter the old sizing dropped.
            #expect(node.size > head.content.utf8.count)
            // Enumeration and single-item resolution share the cached render:
            // identical versions, not just identical sizes.
            let sameRenderNode = try #require(
                projection.node(for: view.makeID(source.id.rawValue)))
            #expect(node.contentVersion == sameRenderNode.contentVersion)
        }
    }

    /// Change 1: the sibling frontmatter carries an id-less origin-URL entry
    /// (`- resource: https://…`) AFTER the id-carrying self-reference — for
    /// the byteless+head+URL shape AND the with-bytes+head+URL shape (a
    /// website-snapshot-like fetched PDF).
    @Test func siblingFrontmatterCarriesOriginURLForURLShapedIdentities() throws {
        let fixture = try makeStore()
        let byteless = try addBytelessSource(
            fixture.store, filename: "Warp Talk", mimeType: MimeType.videoYouTube,
            externalIdentity: originURL)
        _ = try fixture.store.appendProcessedMarkdown(
            sourceID: byteless.id, content: "Transcript.", origin: .extraction, note: nil)
        let snapshot = try fixture.store.addSource(
            filename: "report.pdf", data: Data("%PDF-1.4 snapshot".utf8),
            mimeType: "application/pdf",
            provenance: bytelessProvenance(externalIdentity: "https://example.com/report"))
        _ = try fixture.store.appendProcessedMarkdown(
            sourceID: snapshot.id, content: "# Extracted", origin: .extraction, note: nil)
        let projection = makeProjection(fixture)
        for (source, origin) in [(byteless, originURL),
                                 (snapshot, "https://example.com/report")] {
            let content = String(
                decoding: projection.contents(
                    for: Projection.Identity.sourceMarkdownByName(source.id.rawValue))
                    ?? Data(),
                as: UTF8.self)
            // yamlString always double-quotes scalar values, so the origin
            // entry renders as: - resource: "https://…"
            #expect(content.contains("- resource: \"\(origin)\""),
                "sibling frontmatter must carry the origin URL")
            // Truthful ordering: the id-carrying self-reference leads, the
            // origin entry follows it.
            guard let selfRefRange = content.range(of: "- id: "),
                  let originRange = content.range(of: "- resource: \"\(origin)\"") else {
                Issue.record("expected self-reference + origin entry in frontmatter")
                return
            }
            #expect(selfRefRange.lowerBound < originRange.lowerBound)
        }
    }

    /// Change 1 truthful-omissive half: a BARE video id (YouTube) and a nil
    /// identity produce NO origin-URL line — the sibling carries only the
    /// id-carrying self-reference.
    @Test func siblingOmitsOriginURLForNonURLIdentities() throws {
        let fixture = try makeStore()
        let bareID = try addBytelessSource(
            fixture.store, filename: "Warp Talk", mimeType: MimeType.videoYouTube,
            externalIdentity: "tUPPVhBBcoM")
        _ = try fixture.store.appendProcessedMarkdown(
            sourceID: bareID.id, content: "Transcript.", origin: .extraction, note: nil)
        let anonymous = try fixture.store.addSource(
            filename: "doc.pdf", data: Data("%PDF-1.4 x".utf8), mimeType: "application/pdf")
        _ = try fixture.store.appendProcessedMarkdown(
            sourceID: anonymous.id, content: "# Extracted", origin: .extraction, note: nil)
        let projection = makeProjection(fixture)
        for source in [bareID, anonymous] {
            let content = String(
                decoding: projection.contents(
                    for: Projection.Identity.sourceMarkdownByName(source.id.rawValue))
                    ?? Data(),
                as: UTF8.self)
            #expect(!content.contains("- resource: http"),
                "\(source.filename): no usable URL → no origin-URL entry")
            #expect(content.contains("- id: "), "self-reference still present")
        }
    }

    /// Change 1 version semantics: the origin reference is id-less, so the
    /// provenance digest folds its URL — changing the origin URL changes the
    /// digest, and with it the sibling's `:prov:` content-version fold
    /// (existing mounts refetch). Also: appending an origin entry moves the
    /// digest relative to the self-reference alone.
    @Test func changingOriginURLChangesTheSiblingContentVersion() {
        let a = OKFSourceReference(resource: .url(URL(string: "https://example.com/a")!))
        let b = OKFSourceReference(resource: .url(URL(string: "https://example.com/b")!))
        #expect(Projection.provenanceDigest([a]) != Projection.provenanceDigest([b]),
            "the digest must distinguish origin URLs")
        let selfRef = OKFSourceReference(
            resource: .bundlePath("/sources/by-id/X.pdf"),
            title: "X", id: "X", usageCount: 0)
        #expect(Projection.provenanceDigest([selfRef])
            != Projection.provenanceDigest([selfRef, a]),
            "adding the origin reference must advance the digest")
    }
}

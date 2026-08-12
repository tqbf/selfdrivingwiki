#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCodeHighlighting
@testable import WikiFSEngine
@testable import WikiFSCore

/// Fidelity tests for the source web reader's Markdown→HTML renderer. The
/// renderer receives RAW markdown (wiki links + footnotes are pre-processed into
/// ordinary markdown links before it runs — see SourceWebView's pre-pass), so
/// these feed standard Markdown and assert the HTML structure.
struct MarkdownHTMLRendererTests {

    @Test("#908 malformed quote anchors stay within their own wiki link")
    func issue908MalformedQuoteAnchorsDoNotConsumeFollowingParagraphs() {
        let sourceID = "01KY7MKKGGFHF6SY6QHKVMT3GX"
        let projectionFilename = "ScalaTestingWithSpecs2.md–\(sourceID).md"
        // This is the exact stored form from the failing page: the quoted
        // passage ends with TWO quotes before `]]`. It is malformed, but a
        // reader must still bound the link at that delimiter rather than turn
        // following paragraphs into one giant link.
        let malformedFragments = [
            "\"The location for tests is in the \"test\" folder.\"\"",
            "\"The expression that follows the must keyword are known as matchers.\"\"",
            "\"Mocks are used to isolate unit tests against external dependencies.\"\"",
            "\"abstract database access behind a repository layer.\"\"",
        ]
        let sentences = [
            "See [[source:\(projectionFilename)#\(malformedFragments[0])]] for test directory organization and sbt console commands.",
            "See \(projectionFilename) for Eclipse integration requirements.",
            "See [[source:\(projectionFilename)#\(malformedFragments[1])]] for matcher details.",
            "See [[source:\(projectionFilename)#\(malformedFragments[2])]] for Mockito usage in specs2.",
            "See [[source:\(projectionFilename)#\(malformedFragments[3])]] for decoupling models and repositories.",
        ]

        let prepared = ReaderMarkdown.prepared(sentences.joined(separator: "\n\n")) { name, kind in
            name == projectionFilename && kind == .source
        }
        let html = MarkdownHTMLRenderer.render(prepared, options: .disabled)

        #expect(html.components(separatedBy: "wiki://source").count - 1 == 4)
        #expect(!html.contains("for test directory organization and sbt console commands. See"),
                "First link consumed the next paragraph. HTML: \(html)")
        #expect(!html.contains("for Mockito usage in specs2. See"),
                "Third link consumed the next paragraph. HTML: \(html)")
    }

    @Test("#908 keeps every citation sentence through the reader pipeline")
    func issue908LegacySourceProjectionNameRetainsAllSentences() {
        let sourceID = "01KY7MKKGGFHF6SY6QHKVMT3GX"
        let projectionFilename = "ScalaTestingWithSpecs2.md–\(sourceID).md"
        let sentences = [
            "See [[source:\(projectionFilename)#\"The location for tests is in the \"test\" folder.\"]] for test directory organization and sbt console commands.",
            "See \(projectionFilename) for Eclipse integration requirements.",
            "See [[source:\(projectionFilename)#\"The expression that follows the must keyword are known as matchers.\"]] for matcher details.",
            "See [[source:\(projectionFilename)#\"Mocks are used to isolate unit tests against external dependencies.\"]] for Mockito usage in specs2.",
            "See [[source:\(projectionFilename)#\"abstract database access behind a repository layer.\"]] for decoupling models and repositories.",
        ]

        let prepared = ReaderMarkdown.prepared(sentences.joined(separator: "\n\n")) { name, kind in
            name == projectionFilename && kind == .source
        }
        let html = MarkdownHTMLRenderer.render(prepared, options: .disabled)

        for sentence in [
            "for test directory organization and sbt console commands.",
            "for Eclipse integration requirements.",
            "for matcher details.",
            "for Mockito usage in specs2.",
            "for decoupling models and repositories.",
        ] {
            #expect(html.contains(sentence), "Missing sentence: \(sentence). HTML: \(html)")
        }
        #expect(html.components(separatedBy: "wiki://source").count - 1 == 4)
    }

    @Test func sourceFrontmatterIsExcludedBeforeRendering() {
        let markdown = """
        ---
        title: Example source
        tags:
          - demo
        ---

        # Hello

        This is the source body.
        """

        let prepared = ReaderMarkdown.prepared(
            markdown,
            contentKind: .source,
            isResolved: { _, _ in true })
        let html = MarkdownHTMLRenderer.render(prepared, options: .disabled)

        #expect(html == "<h1 id=\"hello\">Hello</h1><p>This is the source body.</p>")
    }

    @Test func headingWithSlug() {
        #expect(MarkdownHTMLRenderer.render("# Hello", options: .disabled) == "<h1 id=\"hello\">Hello</h1>")
    }

    @Test func headingSlugLowercasesAndDashes() {
        #expect(MarkdownHTMLRenderer.render("## My Section", options: .disabled) == "<h2 id=\"my-section\">My Section</h2>")
    }

    @Test func paragraphWithInline() {
        let html = MarkdownHTMLRenderer.render("This is **bold** and *italic*.", options: .disabled)
        #expect(html == "<p>This is <strong>bold</strong> and <em>italic</em>.</p>")
    }

    @Test func strikethrough() {
        #expect(MarkdownHTMLRenderer.render("~~done~~", options: .disabled) == "<p><del>done</del></p>")
    }

    @Test func inlineCode() {
        let html = MarkdownHTMLRenderer.render("Use `swift build` now.", options: .disabled)
        #expect(html == "<p>Use <code>swift build</code> now.</p>")
    }

    @Test func fencedCodeBlockWithLanguage() {
        let md = "```swift\nlet x = 1\n```"
        let html = MarkdownHTMLRenderer.render(md, options: .reader)
        #expect(html.contains("<pre><code class=\"language-swift\">"))
        #expect(html.contains("<span class=\"sdw-code-keyword\">let</span> x"))
        #expect(html.contains("<span class=\"sdw-code-number\">1</span>"))
    }

    @Test func highlightedHTMLFenceRemainsInertAndTextEquivalent() {
        let source = "<script>alert('x')</script>\n"
        let html = MarkdownHTMLRenderer.render("```html\n\(source)```", options: .reader)
        #expect(html.contains("class=\"language-html\""))
        #expect(html.contains("&lt;"))
        #expect(html.contains("script"))
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("sdw-code-"))
        #expect(codeTextContent(in: html) == source)
    }

    @Test("all five approved fenced-code languages produce closed-palette spans")
    func approvedFenceLanguagesHighlightWithoutChangingText() {
        let cases = [
            ("java", "class Example { int value = 1; }\n"),
            ("scala", "object Example { val value = 1 }\n"),
            ("html", "<div class=\"example\">value</div>\n"),
            ("swift", "let value = 1\n"),
            ("json", "{\"value\": 1}\n"),
        ]

        for (language, source) in cases {
            let html = MarkdownHTMLRenderer.render("```\(language)\n\(source)```", options: .reader)
            #expect(html.contains("class=\"language-\(language)\""), "Missing language class for \(language)")
            #expect(html.contains("sdw-code-"), "No highlighted token for \(language)")
            #expect(codeTextContent(in: html) == source, "Changed code text for \(language)")
        }
    }

    @Test("only approved fence-info aliases select a grammar")
    func closedFenceLanguageAliasesPreserveOriginalClass() {
        let aliases = [
            ("xml", "<node>text</node>\n"),
            ("jsonc", "// comment\n{\"value\": 1}\n"),
        ]
        for (alias, source) in aliases {
            let html = MarkdownHTMLRenderer.render("```\(alias)\n\(source)```", options: .reader)
            #expect(html.contains("class=\"language-\(alias)\""))
            #expect(html.contains("sdw-code-"))
            #expect(codeTextContent(in: html) == source)
        }

        let unsupported = MarkdownHTMLRenderer.render("```javascript\nconst value = '<script>';\n```", options: .reader)
        #expect(unsupported.contains("class=\"language-javascript\""))
        #expect(!unsupported.contains("sdw-code-"))
        #expect(!unsupported.contains("<script>"))
    }

    @Test("render entry points require an explicit typed policy")
    func renderEntryPointsRequireExplicitPolicy() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let renderer = try String(
            contentsOf: repository.appending(path: "Sources/WikiFS/Reader/MarkdownHTMLRenderer.swift"),
            encoding: .utf8)
        let embedder = try String(
            contentsOf: repository.appending(path: "Sources/WikiFS/Reader/TransclusionEmbedder.swift"),
            encoding: .utf8)

        #expect(renderer.contains("options: MarkdownRenderOptions,"))
        #expect(!renderer.contains("options: MarkdownRenderOptions ="))
        #expect(embedder.contains("options: MarkdownRenderOptions\n"))
        #expect(!embedder.contains("options: MarkdownRenderOptions ="))
    }

    @Test("highlighting limits and cancellation fail closed to ordinary escaped code")
    func highlightingLimitsAndCancellationFallBackToPlainCode() {
        let oversized = String(repeating: "x", count: CodeHighlightingPolicy.maximumHighlightedSourceBytes + 1)
        #expect(CodeSyntaxHighlighter.highlightedHTML(
            source: oversized,
            language: .swift,
            isCancelled: { false }) == nil)
        #expect(CodeSyntaxHighlighter.highlightedHTML(
            source: "let value = 1",
            language: .swift,
            isCancelled: { true }) == nil)

        let fence = "```swift\nlet value = 1\n```"
        let markdown = Array(repeating: fence, count: CodeHighlightingPolicy.maximumHighlightedBlockCount + 1)
            .joined(separator: "\n\n")
        let html = MarkdownHTMLRenderer.render(markdown, options: .reader)
        let marker = "<span class=\"sdw-code-keyword\">let</span>"
        #expect(html.components(separatedBy: marker).count - 1 == CodeHighlightingPolicy.maximumHighlightedBlockCount)
    }

    @Test("ineligible fences do not consume a document highlight budget")
    func ineligibleFencesDoNotConsumeDocumentHighlightBudget() {
        let oversized = String(
            repeating: "x",
            count: CodeHighlightingPolicy.maximumHighlightedSourceBytes + 1)
        let fence = "```swift\nlet value = 1\n```"
        let options = MarkdownRenderOptions(
            codeHighlighting: .enabled(HighlightedCodeBlockBudget(limit: 1)),
            rendererEmbedProjection: nil,
            documentIdentity: nil,
            rendererActivationAdmission: nil)

        let html = MarkdownHTMLRenderer.render(
            "```swift\n\(oversized)\n```\n\n\(fence)",
            options: options)

        let oversizedIsEligible = CodeSyntaxHighlighter.isEligibleSource(
            oversized,
            language: .swift,
            isCancelled: { false })
        #expect(!oversizedIsEligible)
        #expect(html.components(separatedBy: "<span class=\"sdw-code-keyword\">let</span>").count - 1 == 1)
    }

    @Test func regularLink() {
        let html = MarkdownHTMLRenderer.render("[ex](https://example.com)", options: .disabled)
        #expect(html == "<p><a href=\"https://example.com\" title=\"https://example.com\">ex</a></p>")
    }

    @Test func wikiLinkHrefPassesThrough() {
        // After the pre-pass, a wiki link is an ordinary markdown link with a
        // wiki:// destination. The renderer must pass it through verbatim so the
        // navigation delegate can route it.
        let html = MarkdownHTMLRenderer.render("[Page](wiki://page/Page)", options: .disabled)
        #expect(html == "<p><a href=\"wiki://page/Page\" title=\"wiki://page/Page\">Page</a></p>")
    }

    @Test func unorderedList() {
        let html = MarkdownHTMLRenderer.render("- a\n- b", options: .disabled)
        #expect(html == "<ul><li>a</li><li>b</li></ul>")
    }

    @Test func orderedList() {
        let html = MarkdownHTMLRenderer.render("1. one\n2. two", options: .disabled)
        #expect(html == "<ol><li>one</li><li>two</li></ol>")
    }

    @Test func blockquote() {
        let html = MarkdownHTMLRenderer.render("> quote", options: .disabled)
        #expect(html == "<blockquote><p>quote</p></blockquote>")
    }

    @Test func thematicBreak() {
        #expect(MarkdownHTMLRenderer.render("---", options: .disabled) == "<hr>")
    }

    @Test func escapesHTMLSpecialCharacters() {
        let html = MarkdownHTMLRenderer.render("a < b > c & d", options: .disabled)
        #expect(html == "<p>a &lt; b &gt; c &amp; d</p>")
    }

    @Test func tableRendersHeaderAndBody() {
        let md = """
        | A   | B   |
        | --- | --- |
        | 1   | 2   |
        """
        let html = MarkdownHTMLRenderer.render(md, options: .disabled)
        #expect(html == "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>")
    }

    @Test func headingSlugDedupMatchesAnchorBlock() {
        // Duplicate headings must dedup the same way AnchorBlock.makeSlug does,
        // so #fragment resolution stays consistent between the two readers.
        let html = MarkdownHTMLRenderer.render("# Overview\n\n# Overview", options: .disabled)
        #expect(html == "<h1 id=\"overview\">Overview</h1><h1 id=\"overview-1\">Overview</h1>")
    }

    private func codeTextContent(in html: String) -> String {
        guard let codeStart = html.range(of: ">"),
              let codeEnd = html.range(of: "</code>")
        else {
            Issue.record("Expected a code element: \(html)")
            return ""
        }
        let content = html[codeStart.upperBound..<codeEnd.lowerBound]
        var text = ""
        var insideTag = false
        for character in content {
            switch character {
            case "<": insideTag = true
            case ">" where insideTag: insideTag = false
            default:
                if !insideTag {
                    text.append(character)
                }
            }
        }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: Mermaid

    @Test func mermaidFenceEmitsLanguageClassAndEscaping() {
        // The mermaid bootstrap depends on visitCodeBlock emitting the exact
        // `class="language-mermaid"` and HTML-escaping the body (so textContent
        // un-escapes it back to the diagram source). Uses `contains` rather than
        // == because cmark keeps the trailing newline in fenced code.
        let html = MarkdownHTMLRenderer.render("```mermaid\ngraph TD\nA-->B\n```", options: .disabled)
        #expect(html.contains(#"class="language-mermaid""#))
        #expect(html.contains("A--&gt;B"))   // escape(): > → &gt;
    }

    @Test func richFenceCardsRenderStaticMarkupWhenProjectionAllowsThem() throws {
        let projection = RendererEmbedProjection(
            sourceEmbeds: [:],
            richFenceAliases: Set(MarkdownRichFenceAlias.allCases))
        let document = MarkdownDocumentIdentity(
            pageID: .init(rawValue: "01HTESTPAGE000000000000001"),
            pageVersionID: .init(rawValue: "01HTESTPV00000000000000001"))
        let admission = RendererEmbedActivationAdmission(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            capability: .init(rawValue: "capability"),
            generation: 1)
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: projection,
            documentIdentity: document,
            rendererActivationAdmission: admission)

        let bytes = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let expectedBlock = try! MarkdownFencedBlock(
            documentIdentity: document,
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: bytes)
        guard let blockID = expectedBlock.blockID else {
            Issue.record("expected a block ID for the document-backed JSON Canvas fence")
            return
        }
        let expectedArtifact = try! RendererEmbeddedContent.InlineArtifact(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            blockID: blockID,
            fenceKind: .jsoncanvas,
            mimeType: .init(rawValue: "application/json")!,
            bytes: bytes)
        let expectedPackageID = try #require(RendererPackageID(rawValue: "org.selfdrivingwiki.builtin"))
        let expectedVersion = try #require(RendererPackageVersion(rawValue: "1.0.0"))
        let expectedRegistrationID = try #require(RendererRegistrationID(rawValue: "json-canvas"))
        let expectedReference = RendererReference(
            packageID: expectedPackageID,
            version: expectedVersion,
            registrationID: expectedRegistrationID)
        admission.register(context: RendererEmbedActivationContext(
            pageID: document.pageID,
            pageVersionID: document.pageVersionID,
            blockID: blockID,
            rendererReference: expectedReference,
            input: .inlineArtifact(expectedArtifact),
            capability: admission.capability,
            generation: admission.generation))

        let jsonCanvas = MarkdownHTMLRenderer.render("```jsoncanvas\n{\"nodes\":[],\"edges\":[]}\n```", options: options)
        #expect(jsonCanvas.contains("sdw-renderer-card"))
        #expect(jsonCanvas.contains("JSON Canvas"))
        #expect(jsonCanvas.contains("renderer-action://open"))
        #expect(jsonCanvas.contains("package=org.selfdrivingwiki.builtin"))
        #expect(jsonCanvas.contains("registration=json-canvas"))
        #expect(jsonCanvas.contains("input="))
        #expect(jsonCanvas.contains("data-renderer-input=\"{"))
        #expect(!jsonCanvas.contains("data-renderer-input=\"null\""))
        guard case let .inlineArtifact(artifact) = rendererBridgeInput(in: jsonCanvas) else {
            Issue.record("expected an inline artifact renderer input")
            return
        }
        #expect(artifact.mimeType.rawValue == "application/json")

        let excalidraw = MarkdownHTMLRenderer.render("```excalidraw\n{\"type\":\"excalidraw\",\"version\":2,\"elements\":[]}\n```", options: options)
        #expect(excalidraw.contains("sdw-renderer-card"))
        #expect(excalidraw.contains("Excalidraw"))
        #expect(excalidraw.contains("Interact"))

        let mermaid = MarkdownHTMLRenderer.render("```mermaid\ngraph TD\nA-->B\n```", options: options)
        #expect(mermaid.contains(#"class="language-mermaid""#))
        #expect(!mermaid.contains("sdw-renderer-card"))
    }

    @Test("oversized rich fences fall back to escaped code without renderer metadata")
    func oversizedRichFencesUseEscapedFallbackWithoutRendererMetadata() {
        let projection = RendererEmbedProjection(
            sourceEmbeds: [:],
            richFenceAliases: Set(MarkdownRichFenceAlias.allCases))
        let document = MarkdownDocumentIdentity(
            pageID: .init(rawValue: "01HTESTPAGE000000000000001"),
            pageVersionID: .init(rawValue: "01HTESTPV00000000000000001"))
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: projection,
            documentIdentity: document,
            rendererActivationAdmission: nil)
        let oversized = String(
            repeating: "x",
            count: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1)

        let html = MarkdownHTMLRenderer.render("```jsoncanvas\n\(oversized)\n```", options: options)

        #expect(html.contains("<pre><code class=\"language-jsoncanvas\">"))
        #expect(!html.contains("sdw-renderer-card"))
        #expect(!html.contains("renderer-action://open"))
        #expect(!html.contains("data-renderer-input=\"null\""))
    }

    @Test("renderer action URLs decode the exact typed input under the current admission")
    func rendererActionURLDecodesTypedInput() throws {
        let fixture = try makeRendererActivationFixture()
        let route = try #require(
            WikiReaderView.rendererActivationRoute(
                for: fixture.url,
                admission: fixture.admission,
                isMainFrame: true))
        #expect(route.reference == fixture.reference)
        #expect(route.input == fixture.input)
    }

    @Test("renderer action URLs reject forged HTML, stale admissions, and field substitutions")
    func rendererActionURLRejectsForgedEnvelope() throws {
        let fixture = try makeRendererActivationFixture()
        #expect(WikiReaderView.rendererActivationRoute(for: URL(string: "https://example.com")!, admission: fixture.admission, isMainFrame: true) == nil)
        #expect(WikiReaderView.rendererActivationRoute(for: fixture.url, admission: nil, isMainFrame: true) == nil)
        #expect(WikiReaderView.rendererActivationRoute(for: fixture.url, admission: fixture.admission, isMainFrame: false) == nil)

        for mutate in [
            ("generation", "99"),
            ("page", "01HTESTPAGE000000000000099"),
            ("pageVersion", "01HTESTPV00000000000000099"),
            ("blockPage", "01HTESTPAGE000000000000099"),
            ("blockPageVersion", "01HTESTPV00000000000000099"),
            ("blockOrdinal", "9"),
            ("block", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
            ("package", "org.selfdrivingwiki.other"),
            ("version", "2.0.0"),
            ("registration", "other"),
            ("mime", "text/plain")
        ] {
            guard var components = URLComponents(url: fixture.url, resolvingAgainstBaseURL: false) else {
                Issue.record("expected forged URL components to be constructible")
                continue
            }
            let queryItems = components.queryItems ?? []
            components.queryItems = queryItems.map { item in
                if item.name == mutate.0 {
                    return URLQueryItem(name: item.name, value: mutate.1)
                }
                return item
            }
            let forgedURL = try #require(components.url)
            #expect(WikiReaderView.rendererActivationRoute(for: forgedURL, admission: fixture.admission, isMainFrame: true) == nil)
        }
    }

    @Test("rich fences stay static when no host admission exists")
    func rendererActionURLStaysStaticWithoutAdmission() throws {
        let projection = RendererEmbedProjection(
            sourceEmbeds: [:],
            richFenceAliases: [.jsoncanvas])
        let document = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01HTESTPAGE000000000000001"),
            pageVersionID: PageVersionID(rawValue: "01HTESTPV00000000000000001"))
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: projection,
            documentIdentity: document,
            rendererActivationAdmission: nil)
        let html = MarkdownHTMLRenderer.render("```jsoncanvas\n{\"nodes\":[],\"edges\":[]}\n```", options: options)

        #expect(html.contains("sdw-renderer-card"))
        #expect(!html.contains("renderer-action://open"))
        #expect(!html.contains("data-renderer-input="))
    }

    @Test func documentHTMLEmbedsNoScriptWhenLibAbsent() {
        // Under `swift test` there's no .app bundle, so `mermaidLib` is nil →
        // documentHTML embeds NO <script>, and the mermaid block is preserved as
        // ordinary code. Pins graceful degradation (AC.4/AC.5).
        let h = WikiReaderView.documentHTML("<pre><code class=\"language-mermaid\">graph TD</code></pre>")
        #expect(!h.contains("<script>"))
        #expect(h.contains(#"class="language-mermaid""#))
    }

    // MARK: - Inline HTML passthrough (Phase 4a embeds)

    @Test func rawInlineHTMLFromEmbedSurvivesRender() {
        // The embed pre-pass emits raw inline HTML (e.g. `<img src="wiki-blob://…">`).
        // swift-markdown parses it as InlineHTML, and the renderer must pass it
        // through verbatim — otherwise the embed is silently dropped. This test
        // guards against someone removing visitInlineHTML/visitHTMLBlock.
        let id = SourceID(rawValue: "01HTESTRENDER0000000000001")
        let prepared = WikiLinkMarkdown.linkified(
            "Here is ![[source:img.png]] inline.",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "image/png") }
        )
        let html = MarkdownHTMLRenderer.render(prepared, options: .disabled)
        #expect(html.contains(#"<img src="wiki-blob://source/\#(id.rawValue)""#))
        #expect(html.contains("wiki-embed"))
    }

    // MARK: - Mermaid embed survives the markdown→HTML pipeline (#736).

    /// A `.mmd` source embed (`![[source:diagram.mmd]]`) must survive the
    /// reader's `MarkdownHTMLRenderer` as a single intact
    /// `<pre><code class="language-mermaid">…</code></pre>` whose
    /// `textContent` CSS-decodes back to the original diagram source —
    /// otherwise the reader's `mermaidBootstrapJS` reads garbled
    /// `code.textContent` and `mermaid.parse()` fails with
    /// "Syntax error in text". This checks the four contexts that broke the
    /// previous raw-`<div>` emit: paragraph surrounds, a blank line inside
    /// the diagram, the embed inside a list item, and the embed mid-paragraph.
    @Test func mermaidEmbedSurvivesMarkdownRendererInAllContexts() {
        let id = SourceID(rawValue: "01HTESTMERMAID0000000000001")
        let cases: [(String, String, String)] = [
            ("paragraph-surround",
             "intro.\n\n![[source:diagram.mmd]]\n\noutro.",
             "graph TD\n    A --> B\n    B --> C\n"),
            ("blank-line-in-diagram",
             "intro.\n\n![[source:diagram.mmd]]\n\noutro.",
             "graph TD\n    A --> B\n\n    B --> C\n"),
            ("inside-list",
             "- before\n- ![[source:diagram.mmd]]\n- after",
             "graph TD\n    A --> B\n    B --> C\n"),
            ("mid-paragraph",
             "text ![[source:diagram.mmd]] more text",
             "graph TD\n    A --> B\n    B --> C\n"),
        ]
        for (label, body, diagramSource) in cases {
            let prepared = WikiLinkMarkdown.linkified(
                body,
                isResolved: { _, _ in true },
                embedInfo: { _ in
                    WikiLinkMarkdown.SourceEmbedInfo(
                        id: id, mimeType: MimeType.mermaid,
                        target: EmbedTarget(
                            kind: .diagram,
                            url: "wiki://source/\(id.rawValue)",
                            content: diagramSource)
                    )
                }
            )
            let html = MarkdownHTMLRenderer.render(prepared, options: .disabled)
            // Exactly one mermaid code element survives.
            let mermaidCount = html.components(
                separatedBy: "class=\"language-mermaid\"").count - 1
            #expect(mermaidCount == 1,
                    "\(label): expected one `<code class=\"language-mermaid\">`, got \(mermaidCount). HTML:\n\(html)")
            // visitCodeBlock escapes `>` exactly ONCE → `&gt;`. The previous
            // raw-div path double-escaped to `&amp;gt;` (literal `&gt;`) in
            // some contexts, tripping mermaid's parser.
            #expect(html.contains("A --&gt; B"),
                    "\(label): expected `A --&gt; B` in HTML:\n\(html)")
            #expect(!html.contains("&amp;gt;"),
                    "\(label): double-escaped `&amp;gt;` (literal `&gt;`) in HTML:\n\(html)")
            // The diagram text is NOT wrapped in `<p>` tags by the markdown
            // converter — it flows into the `<pre><code>` unchanged.
            #expect(!html.contains("<p>graph TD"),
                    "\(label): diagram body wrapped in `<p>`. HTML:\n\(html)")
            // The `<pre>` wraps the `<code>` — no orphaned fragments.
            #expect(html.contains("<pre><code class=\"language-mermaid\">"),
                    "\(label): missing `<pre><code class=\"language-mermaid\">`. HTML:\n\(html)")
        }
    }

    /// Mermaid source containing a ``` triple-backtick run (rare, but
    /// possible in node labels) must not prematurely close the fence we
    /// emit: we pick a fence length strictly longer than any run in the
    /// diagram body (CommonMark §4.5).
    @Test func mermaidEmbedWithBackticksInSourceUsesLongerFence() {
        let id = SourceID(rawValue: "01HTESTMERMAID0000000000002")
        let diagram = "graph TD\n    A[\"has ``` triple backticks\"] --> B"
        let prepared = WikiLinkMarkdown.linkified(
            "![[source:diagram.mmd]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(
                    id: id, mimeType: MimeType.mermaid,
                    target: EmbedTarget(
                        kind: .diagram,
                        url: "wiki://source/\(id.rawValue)", content: diagram)
                )
            }
        )
        let html = MarkdownHTMLRenderer.render(prepared, options: .disabled)
        // The 3-backtick run inside the body is preserved verbatim, AND the
        // outer fence (4+ backticks) keeps the block intact.
        #expect(html.contains("\"has ``` triple backticks\""))
        #expect(html.contains("class=\"language-mermaid\""))
        // No premature close → only one code element.
        let count = html.components(
            separatedBy: "class=\"language-mermaid\"").count - 1
        #expect(count == 1)
    }

    private func rendererBridgeInput(in html: String) -> RendererBridgeInput? {
        guard let start = html.range(of: #"data-renderer-input=""#) else { return nil }
        guard let end = html[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let encoded = String(html[start.upperBound..<end])
        let json = encoded
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        return try? JSONDecoder().decode(RendererBridgeInput.self, from: Data(json.utf8))
    }
}

private struct RendererActivationFixture {
    let admission: RendererEmbedActivationAdmission
    let reference: RendererReference
    let input: RendererBridgeInput
    let url: URL
}

private extension MarkdownHTMLRendererTests {
    func makeRendererActivationFixture() throws -> RendererActivationFixture {
        let bytes = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let pageID = PageID(rawValue: "01HTESTPAGE000000000000001")
        let pageVersionID = PageVersionID(rawValue: "01HTESTPV00000000000000001")
        let block = try MarkdownFencedBlock(
            documentIdentity: .init(pageID: pageID, pageVersionID: pageVersionID),
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: bytes)
        let blockID = try #require(block.blockID)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: blockID,
            fenceKind: .jsoncanvas,
            mimeType: .init(rawValue: "application/json")!,
            bytes: bytes)
        let input = RendererBridgeInput.inlineArtifact(artifact)
        let encodedInput = try String(decoding: JSONEncoder().encode(input), as: UTF8.self)
        let admission = RendererEmbedActivationAdmission(
            pageID: pageID,
            pageVersionID: pageVersionID,
            capability: .init(rawValue: "capability"),
            generation: 7)
        let packageID = try #require(RendererPackageID(rawValue: "org.selfdrivingwiki.builtin"))
        let version = try #require(RendererPackageVersion(rawValue: "1.0.0"))
        let registrationID = try #require(RendererRegistrationID(rawValue: "json-canvas"))
        let reference = RendererReference(
            packageID: packageID,
            version: version,
            registrationID: registrationID)
        let activationContext = RendererEmbedActivationContext(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: blockID,
            rendererReference: reference,
            input: input,
            capability: admission.capability,
            generation: admission.generation)
        admission.register(context: activationContext)
        var components = URLComponents()
        components.scheme = "renderer-action"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "package", value: "org.selfdrivingwiki.builtin"),
            URLQueryItem(name: "version", value: "1.0.0"),
            URLQueryItem(name: "registration", value: "json-canvas"),
            URLQueryItem(name: "input", value: encodedInput),
            URLQueryItem(name: "capability", value: admission.capability.rawValue),
            URLQueryItem(name: "generation", value: String(admission.generation)),
            URLQueryItem(name: "page", value: pageID.rawValue),
            URLQueryItem(name: "pageVersion", value: pageVersionID.rawValue),
            URLQueryItem(name: "block", value: blockID.digest.hex),
            URLQueryItem(name: "blockPage", value: blockID.pageID.rawValue),
            URLQueryItem(name: "blockPageVersion", value: blockID.pageVersionID.rawValue),
            URLQueryItem(name: "blockOrdinal", value: String(blockID.parserOrdinal)),
            URLQueryItem(name: "mime", value: artifact.mimeType.rawValue)
        ]
        return RendererActivationFixture(
            admission: admission,
            reference: reference,
            input: input,
            url: try #require(components.url))
    }
}
#endif

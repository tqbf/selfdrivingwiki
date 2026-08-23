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

    @Test("a Mermaid fence title remains presentation metadata")
    func titledMermaidFenceKeepsTitleOutOfClassAndSource() {
        let source = "graph TD\nA-->B\n"
        let title = "System architecture"
        let html = MarkdownHTMLRenderer.render(
            "```mermaid \"\(title)\"\n\(source)```",
            options: .disabled)

        #expect(html == "<pre><code class=\"language-mermaid\">graph TD\nA--&gt;B\n</code></pre>")
        #expect(!html.contains("language-mermaid \(title)"))
        #expect(!html.contains(title))
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

        let bytes = Data("{\"nodes\":[],\"edges\":[]}\n".utf8)
        let fenceInfo = "jsoncanvas \"Roadmap <&>\""
        let expectedBlock = try! MarkdownFencedBlock(
            documentIdentity: document,
            parserOrdinal: 0,
            rawInfoString: fenceInfo,
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

        let jsonCanvas = MarkdownHTMLRenderer.render("```\(fenceInfo)\n{\"nodes\":[],\"edges\":[]}\n```", options: options)
        #expect(jsonCanvas.contains("sdw-renderer-card"))
        #expect(jsonCanvas.contains("data-renderer-expanded=\"false\""))
        #expect(jsonCanvas.contains("aria-label=\"JSON Canvas renderer: Roadmap &lt;&amp;&gt;\""))
        #expect(jsonCanvas.contains("sdw-renderer-card__row"))
        #expect(jsonCanvas.contains("sdw-renderer-card__disclosure"))
        #expect(jsonCanvas.contains("type=\"button\""))
        #expect(jsonCanvas.contains("aria-expanded=\"false\""))
        let expectedExpansionID = "sdw-renderer-\(expectedBlock.digest.hex.prefix(16))-0-expansion"
        #expect(jsonCanvas.contains("aria-controls=\"\(expectedExpansionID)\""))
        #expect(jsonCanvas.contains("id=\"\(expectedExpansionID)\""))
        #expect(jsonCanvas.contains("hidden aria-hidden=\"true\""))
        #expect(jsonCanvas.contains("sdw-renderer-card__expansion"))
        #expect(jsonCanvas.contains("sdw-renderer-card__title"))
        #expect(jsonCanvas.contains("Roadmap &lt;&amp;&gt;"))
        #expect(jsonCanvas.contains("aria-label=\"Expand JSON Canvas renderer: Roadmap &lt;&amp;&gt;\""))
        #expect(jsonCanvas.contains(#"style="min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1 1 auto""#))
        #expect(jsonCanvas.contains("renderer-action://open"))
        #expect(jsonCanvas.contains("sdw-renderer-card__action"))
        #expect(jsonCanvas.contains(">Open in Window</a>"))
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
        #expect(excalidraw.contains("sdw-renderer-card__title"))
        #expect(excalidraw.contains("Open in Window"))

        let mermaid = MarkdownHTMLRenderer.render("```mermaid\ngraph TD\nA-->B\n```", options: options)
        #expect(mermaid.contains("data-renderer-kind=\"mermaid\""))
        #expect(mermaid.contains("data-renderer-expanded=\"false\""))
        #expect(mermaid.contains("aria-expanded=\"false\""))
        #expect(mermaid.contains("data-mermaid-disclosure=\"true\""))
        #expect(mermaid.contains("sdw-mermaid-row__expansion"))
        #expect(mermaid.contains("A--&gt;B"))
        #expect(mermaid.contains("Open in Window"))
        #expect(!mermaid.contains("data-renderer-action=\"expand\""))
        #expect(WikiReaderWebView.rendererAttachmentGeometryJS.contains("data-mermaid-disclosure"))
        #expect(WikiReaderWebView.rendererAttachmentGeometryJS.contains("if(!expanded&&window.__sdwRenderMermaidRow)"))
        #expect(WikiReaderView.mermaidBootstrapJS.contains("data-mermaid-rendering') === 'true'"))
        #expect(WikiReaderView.mermaidBootstrapJS.contains("setAttribute('data-mermaid-rendering', 'true')"))
        #expect(WikiReaderView.mermaidBootstrapJS.contains("removeAttribute('data-mermaid-rendering')"))
        #expect(WikiReaderView.mermaidBootstrapJS.contains("code.parentElement.hidden = false"))
        #expect(WikiReaderView.mermaidBootstrapJS.contains("diagram.textContent = ''"))
        #expect(!WikiReaderView.mermaidBootstrapJS.contains("querySelectorAll('code.language-mermaid')"))
    }

    @Test("an Excalidraw card delegates drawing to the dynamic renderer")
    func excalidrawCardDelegatesToDynamicRenderer() throws {
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
            rendererActivationAdmission: RendererEmbedActivationAdmission(
                pageID: document.pageID,
                pageVersionID: document.pageVersionID,
                capability: .init(rawValue: "capability"),
                generation: 1))

        let drawing = """
        ```excalidraw
        {"type":"excalidraw","version":2,"elements":[\
        {"id":"a","type":"rectangle","x":80,"y":120,"width":220,"height":100,\
        "strokeColor":"#1e1e1e","backgroundColor":"#dbeafe","roundness":{"type":3}},\
        {"id":"b","type":"text","x":130,"y":155,"width":120,"height":30,\
        "strokeColor":"#1e1e1e","text":"Client"}],\
        "appState":{"viewBackgroundColor":"#ffffff"}}
        ```
        """
        let card = MarkdownHTMLRenderer.render(drawing, options: options)
        #expect(card.contains("sdw-renderer-card"))
        #expect(card.contains("Excalidraw"))
        #expect(card.contains("sdw-renderer-card__title"))
        #expect(card.contains("Open in Window"))
        #expect(card.contains("sdw-renderer-card__title--truncated"))
        #expect(card.contains("renderer-action://open"))
        #expect(!card.contains("sdw-renderer-card__preview"))
        #expect(!card.contains("<svg "))
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

    @Test("image renderer action routes preserve exact content and Markdown source versions", arguments: [false, true])
    func imageRendererActionRoutesPreserveExactSourceVersion(useMarkdownVersion: Bool) throws {
        let fixture = try makeImageRendererActivationFixture(useMarkdownVersion: useMarkdownVersion)
        let route = try #require(
            WikiReaderView.rendererActivationRoute(
                for: fixture.url,
                admission: fixture.admission,
                isMainFrame: true))

        #expect(route.reference == fixture.reference)
        #expect(route.input == fixture.input)
    }

    @Test("image renderer action routes reject source identity substitutions")
    func imageRendererActionRoutesRejectSourceIdentitySubstitutions() throws {
        let fixture = try makeImageRendererActivationFixture(useMarkdownVersion: false)
        for mutation in [
            ("sourceID", "01HTESTSOURCE0000000000099"),
            ("sourceVersion", "01HTESTSOURCEVERSION000099"),
            ("sourceDigest", String(repeating: "f", count: 64)),
            ("mime", "image/jpeg"),
            ("registration", "other")
        ] {
            var components = try #require(URLComponents(url: fixture.url, resolvingAgainstBaseURL: false))
            components.queryItems = (components.queryItems ?? []).map { item in
                item.name == mutation.0 ? URLQueryItem(name: item.name, value: mutation.1) : item
            }
            let forgedURL = try #require(components.url)
            #expect(WikiReaderView.rendererActivationRoute(
                for: forgedURL, admission: fixture.admission, isMainFrame: true) == nil)
        }
    }

    @Test("renderer action URLs preserve plus-bearing base64 through URLComponents round-trip")
    func rendererActionURLPreservesPlusBearingBase64RoundTrip() throws {
        let fixture = try makeRendererActivationFixture(bytes: Data("~~~\n".utf8))
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
            rendererActivationAdmission: fixture.admission)

        let html = MarkdownHTMLRenderer.render("```jsoncanvas\n~~~\n```", options: options)
        let actionURL = try #require(rendererActionURL(in: html))
        let components = try #require(URLComponents(url: actionURL, resolvingAgainstBaseURL: false))
        let encodedInput = try #require(components.queryItems?.first(where: { $0.name == "input" })?.value)
        let decodedInput = try JSONDecoder().decode(RendererBridgeInput.self, from: Data(encodedInput.utf8))
        #expect(decodedInput == fixture.input)
        #expect(actionURL.absoluteString.contains("+"))

        let route = try #require(
            WikiReaderView.rendererActivationRoute(
                for: actionURL,
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

    @Test("renderer-action URLs that fail admission stay cancelled by policy")
    func rendererActionURLsFailClosedByPolicy() throws {
        let fixture = try makeRendererActivationFixture()
        guard var components = URLComponents(url: fixture.url, resolvingAgainstBaseURL: false) else {
            Issue.record("expected forged URL components to be constructible")
            return
        }
        components.queryItems = (components.queryItems ?? []).map { item in
            if item.name == "registration" {
                return URLQueryItem(name: item.name, value: "other")
            }
            return item
        }
        let forgedURL = try #require(components.url)
        #expect(WikiReaderView.rendererActivationRoute(for: forgedURL, admission: fixture.admission, isMainFrame: true) == nil)
        #expect(WikiReaderView.rendererActionNavigationPolicy(for: forgedURL) == .cancel)
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
        #expect(html.contains("data-renderer-expanded=\"true\""))
        #expect(html.contains("aria-label=\"JSON Canvas renderer\""))
        #expect(html.contains("aria-expanded=\"true\""))
        #expect(html.contains("aria-label=\"JSON Canvas renderer fallback shown\""))
        #expect(!html.contains("renderer-action://open"))
        #expect(!html.contains("data-renderer-input="))
        #expect(!html.contains("data-renderer-action=\"expand\""))
        #expect(html.contains(#"<p class="sdw-renderer-card__summary">JSON Canvas document fence</p>"#))
        #expect(html.contains("disabled aria-disabled=\"true\""))
        #expect(html.contains("aria-hidden=\"false\""))
        #expect(html.contains("hidden aria-hidden=\"true\"") == false)
        #expect(!html.contains("aria-label=\"Expand JSON Canvas renderer\""))
    }

    @Test("long renderer titles retain an accessible value while visually ellipsizing")
    func longRendererTitlesRetainAccessibleValueWhileVisuallyEllipsizing() {
        let projection = RendererEmbedProjection(
            sourceEmbeds: [:],
            richFenceAliases: [.jsoncanvas])
        let document = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01HTESTPAGE000000000000001"),
            pageVersionID: PageVersionID(rawValue: "01HTESTPV00000000000000001"))
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
        let longTitle = String(repeating: "Long renderer title ", count: 12)
        let html = MarkdownHTMLRenderer.render(
            "```jsoncanvas \"\(longTitle)\"\n{\"nodes\":[],\"edges\":[]}\n```",
            options: options)

        #expect(html.contains("title=\"\(longTitle)\""))
        #expect(html.contains(#"style="min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1 1 auto""#))
        #expect(html.contains(#"class="sdw-renderer-card__action""#))
        #expect(html.contains(#"style="flex:0 0 auto""#))
    }

    @Test("ordinary Markdown images remain unchanged by renderer-card markup")
    func ordinaryMarkdownImagesRemainOrdinaryImages() {
        let html = MarkdownHTMLRenderer.render(
            "![Diagram <&>](https://example.com/diagram.png)",
            options: .disabled)

        #expect(html == #"<p><img src="https://example.com/diagram.png" alt="Diagram &lt;&amp;&gt;"></p>"#)
        #expect(html.contains("sdw-renderer-card") == false)
    }

    @Test("standalone Mermaid renderer contains no inline card chrome")
    func standaloneMermaidRendererOmitsInlineCardChrome() {
        let source = "flowchart LR\nA[Start <&>] --> B[Finish]"
        let html = MermaidRendererWebView.Coordinator.documentHTML(
            source: source,
            library: "window.mermaid = window.mermaid || {};",
            theme: .dark)

        #expect(html.contains(#"id="diagram" class="mermaid""#))
        #expect(html.contains(#"data-mermaid-theme="dark""#))
        #expect(html.contains("theme:'dark'"))
        #expect(html.contains("width: \(Int(PageEditorMetrics.readableContentWidth))px"))
        #expect(html.contains(MermaidRendererAssets.sharedCSS))
        #expect(html.contains(#"id="source" hidden"#) == false)
        #expect(html.contains(#"id="error" role="alert" hidden"#))
        #expect(html.contains("securityLevel:'strict'"))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("flowchart LR"))
        #expect(html.contains("Start &lt;&amp;&gt;"))
        #expect(html.contains("sdw-renderer-card") == false)
        #expect(html.contains("sdw-renderer-card__row") == false)
        #expect(html.contains("data-mermaid-disclosure") == false)
        #expect(html.contains("data-renderer-action") == false)
        #expect(html.contains("Open in Window") == false)
    }

    @Test("standalone Mermaid renderer uses the explicit app theme")
    func standaloneMermaidRendererUsesExplicitTheme() {
        let source = "flowchart LR\nA --> B"
        let library = "window.mermaid = window.mermaid || {};"
        let lightHTML = MermaidRendererWebView.Coordinator.documentHTML(
            source: source,
            library: library,
            theme: .light)
        let darkHTML = MermaidRendererWebView.Coordinator.documentHTML(
            source: source,
            library: library,
            theme: .dark)

        #expect(lightHTML.contains(#"data-mermaid-theme="default""#))
        #expect(lightHTML.contains("theme:'default'"))
        #expect(darkHTML.contains(#"data-mermaid-theme="dark""#))
        #expect(darkHTML.contains("theme:'dark'"))
        #expect(lightHTML.contains("matchMedia") == false)
        #expect(darkHTML.contains("matchMedia") == false)

        let lightIdentity = MermaidRendererWebView.Coordinator.contentIdentity(
            source: source,
            library: library,
            theme: .light)
        let darkIdentity = MermaidRendererWebView.Coordinator.contentIdentity(
            source: source,
            library: library,
            theme: .dark)
        #expect(lightIdentity != darkIdentity)
    }

    @Test("renderer row stylesheet stays compact, relative, focus-visible, and motion-aware")
    func rendererRowStylesUseNativeReaderScaleAndFocus() {
        let html = WikiReaderView.documentHTML("<p>Body</p>")

        #expect(html.contains("background: transparent"))
        #expect(html.contains(".sdw-renderer-card__row { gap: 0.35em; min-height: 2em; cursor: pointer; }"))
        #expect(html.contains("font-size: 0.95em; font-weight: 400"))
        #expect(html.contains(".sdw-renderer-card__disclosure:focus-visible"))
        #expect(html.contains("outline: 2px solid -webkit-focus-ring-color"))
        #expect(html.contains("@media (prefers-reduced-motion: reduce)"))
    }

    @Test("native renderer reservation and geometry use the expansion region below the row")
    func nativeRendererLayoutTargetsExpansionRegion() {
        let script = WikiReaderWebView.rendererAttachmentGeometryJS

        #expect(script.contains("expansion.style.minHeight=height+'px'"))
        #expect(script.contains("e.style.minHeight=height+'px'") == false)
        #expect(script.contains("e.dataset.rendererExpanded==='true'&&expansion?expansion:e"))
        #expect(script.contains("var r=e.getBoundingClientRect()") == false)
        #expect(script.contains("window.__sdwRendererAttachmentRevision=(window.__sdwRendererAttachmentRevision||0)+1;report();"))
        #expect(script.contains("event.target.closest('.sdw-renderer-card__row')"))
        #expect(script.contains("event.target.closest('[data-renderer-action=\"open-window\"]')"))
        #expect(script.contains("action:card.dataset.rendererExpanded==='true'?'collapse':'activate'"))
        #expect(script.contains("sdw-renderer-card__collapse") == false)
        #expect(script.contains("__sdwRendererAttachmentPresentCollapse") == false)
    }

    @Test func documentHTMLEmbedsNoScriptWhenLibAbsent() {
        // Under `swift test` there's no .app bundle, so the shared Mermaid library is nil →
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

    private func rendererActionURL(in html: String) -> URL? {
        guard let start = html.range(of: #"href=""#),
              let end = html[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let encoded = String(html[start.upperBound..<end])
        let urlString = encoded
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: urlString)
    }
}

private struct RendererActivationFixture {
    let admission: RendererEmbedActivationAdmission
    let reference: RendererReference
    let input: RendererBridgeInput
    let url: URL
}

private extension MarkdownHTMLRendererTests {
    func makeImageRendererActivationFixture(useMarkdownVersion: Bool) throws -> RendererActivationFixture {
        let pageID = PageID(rawValue: "01HTESTPAGE000000000000001")
        let pageVersionID = PageVersionID(rawValue: "01HTESTPV00000000000000001")
        let sourceID = SourceID(rawValue: "01HTESTSOURCE0000000000001")
        let bytes = Data(#"{"nodes":[],"edges":[]}"#.utf8)
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let mimeType = try RendererMIMEType(validating: "application/json")
        let source = try RendererEmbeddedContent.Source(
            sourceID: sourceID,
            sourceVersionID: useMarkdownVersion ? nil : SourceVersionID(rawValue: "01HTESTSOURCEVERSION000001"),
            sourceMarkdownVersionID: useMarkdownVersion ? SourceMarkdownVersionID(rawValue: "01HTESTMARKDOWNVERSION0001") : nil,
            mimeType: mimeType,
            bytes: bytes)
        let reference = descriptor.reference
        let projection = try MarkdownImageEmbedProjection(
            siblingSources: ["image.png": source],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [descriptor]),
            inlineCapableReferences: [reference])
        let admission = RendererEmbedActivationAdmission(
            pageID: pageID,
            pageVersionID: pageVersionID,
            capability: .init(rawValue: "capability"),
            generation: 7)
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: nil,
            imageEmbedProjection: projection,
            documentIdentity: .init(pageID: pageID, pageVersionID: pageVersionID),
            rendererActivationAdmission: admission)
        let html = MarkdownHTMLRenderer.render("![System architecture](image.png)", options: options)
        let url = try #require(rendererActionURL(in: html))
        let input: RendererBridgeInput = if let versionID = source.sourceVersionID {
            .source(versionID: versionID)
        } else {
            .markdown(versionID: try #require(source.sourceMarkdownVersionID))
        }
        return RendererActivationFixture(admission: admission, reference: reference, input: input, url: url)
    }

    func makeRendererActivationFixture(bytes: Data = Data("{\"nodes\":[],\"edges\":[]}".utf8)) throws -> RendererActivationFixture {
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

#if os(macOS)
import Foundation
import Testing

@Suite struct SourceDetailRendererArchitectureAuditTests {
    @Test func testNoFormatSpecificRendererRouting() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WikiFS/Sources/SourceDetailView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let forbiddenDeclarations = [
            "FileContentTab",
            "private var availableTabs",
            "pdfOnlyContent",
            "tabbedContent",
            "private var splitContent",
            "selectedTab",
            "private var isPDF",
            "private var isHTMLSource",
            "private var isMermaidSource",
            "private var isBytelessEmbedWithPlayer",
            "Excalidraw",
            "JSON Canvas",
            "MimeType.isMermaid",
            "MimeType.isHTML",
            "ExternalEmbed.target",
            "ExternalEmbed.mediaTabLabel",
            "BuiltInRendererID",
        ]
        for symbol in forbiddenDeclarations {
            #expect(source.contains(symbol) == false, "SourceDetailView must not contain \(symbol)")
        }
        // The only direct PDF decision left in the detail surface is the quote
        // anchor consumer; planner/factory code owns renderer presentation.
        #expect(source.components(separatedBy: "MimeType.isPDF").count == 2)
        #expect(source.contains("requiresPDFQuoteAnchor"))
        #expect(source.contains("SourceRendererPresentationPlanner.showsMarkdownOriginMetadata"))
        // The snapshot loader is the only allowed source-byte read; no body
        // helper or editor path may directly perform a full store read.
        #expect(source.components(separatedBy: "store.sourceBytes(id: file.id)").count == 2)
        #expect(source.contains("RendererHostView"))
        #expect(source.contains("SourceRendererPresentationPlanner"))
        #expect(source.contains("BuiltInRendererFactoryMap.makeView"))
    }

    @Test func rendererShortcutsDoNotOverlapGlobalCommandNumberTabs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("Sources/WikiFS/Window/ContentView.swift"), encoding: .utf8)
        let host = try String(contentsOf: root.appendingPathComponent("Sources/WikiFS/Renderer/RendererHostView.swift"), encoding: .utf8)
        #expect(content.contains("KeyEquivalent(Character(\"\\(i + 1)\")), modifiers: .command"))
        for shortcut in ["1", "2", "3"] {
            #expect(host.contains(".keyboardShortcut(\"\(shortcut)\", modifiers: [.command, .option])"))
            #expect(host.contains(".keyboardShortcut(\"\(shortcut)\", modifiers: .command)") == false)
        }
    }
}
#endif

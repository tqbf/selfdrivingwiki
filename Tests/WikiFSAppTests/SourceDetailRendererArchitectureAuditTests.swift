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
            "BuiltInRendererID",
            "Excalidraw",
            "JSON Canvas",
        ]
        for symbol in forbiddenDeclarations {
            #expect(!source.contains(symbol), "SourceDetailView must not contain \(symbol)")
        }
        #expect(source.contains("RendererHostView"))
        #expect(source.contains("SourceRendererPresentationPlanner"))
        #expect(source.contains("BuiltInRendererFactoryMap.makeView"))
    }
}
#endif

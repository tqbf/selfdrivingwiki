#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

struct PreparedMarkdownDocumentTests {
    @Test func wikiEmbedsRemainTypedWithoutInjectedMarkup() {
        let prepared = ReaderMarkdown.preparedDocument(
            "Body ![[source:diagram.mmd]] and ![[Page]].")

        #expect(prepared.sourceMarkdown == "Body ![[source:diagram.mmd]] and ![[Page]].")
        #expect(prepared.wikiSyntax.count == 2)
        #expect(!prepared.sourceMarkdown.contains("iframe"))
        #expect(!prepared.sourceMarkdown.contains("details"))
        #expect(!prepared.sourceMarkdown.contains("sdw-renderer-card"))
        #expect(!prepared.sourceMarkdown.contains("```mermaid"))
    }

    @Test func footnoteWikiLinksUseTheSameOverlay() {
        let prepared = ReaderMarkdown.preparedDocument(
            "Body[^note].\n\n[^note]: See [[Page]] and ![[source:image.png]].")

        #expect(prepared.wikiSyntax.count == 2)
        #expect(prepared.wikiSyntax.map(\.authoredLiteral) == ["[[Page]]", "![[source:image.png]]"])
        #expect(prepared.sourceMarkdown.contains("wiki-fn-note"))
    }

    @Test func lineTableUsesOneBasedUTF8Columns() {
        let prepared = ReaderMarkdown.preparedDocument("αβ\r\nnext")
        #expect(prepared.lineTable.offset(line: 1, utf8Column: 1) == 0)
        #expect(prepared.lineTable.offset(line: 1, utf8Column: 5) == 4)
        #expect(prepared.lineTable.offset(line: 2, utf8Column: 1) == 6)
    }

    @Test func productionRenderCodeCannotCallLegacyStringBridge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Sources/WikiFS/Reader",
            "Sources/WikiFS/Chats",
        ]
        let manager = FileManager.default
        for relativePath in relativePaths {
            let directory = root.appending(path: relativePath)
            let enumerator = try #require(manager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(!source.contains("ReaderMarkdown.prepared("), "legacy preparation in \(file.path)")
                #expect(!source.contains("WikiLinkMarkdown.linkified("), "legacy linkifier in \(file.path)")
            }
        }
    }
}
#endif

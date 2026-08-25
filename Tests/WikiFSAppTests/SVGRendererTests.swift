#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

@Suite("SVG renderer")
struct SVGRendererTests {
    @Test("host document embeds exact bytes as an inert data image")
    func documentIsInertAndByteExact() throws {
        let bytes = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
          <script>window.evil = true</script>
          <rect width="20" height="20"/>
        </svg>
        """.utf8)

        let html = SVGRendererWebView.Coordinator.documentHTML(bytes: bytes)

        #expect(html.contains("default-src 'none'; img-src data:; style-src 'unsafe-inline'"))
        #expect(html.contains("data:image/svg+xml;base64,\(bytes.base64EncodedString())"))
        #expect(html.contains("<script>window.evil") == false)
        #expect(html.contains("max-width:none"))
    }

    @Test("renderer source disables JavaScript and cancels navigation")
    func rendererSourceKeepsWebKitRestricted() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/WikiFS/Renderer/SVGRendererView.swift"),
            encoding: .utf8)

        #expect(source.contains("preferences.allowsContentJavaScript = false"))
        #expect(source.contains("configuration.websiteDataStore = .nonPersistent()"))
        #expect(source.contains("isInitialDocument ? .allow : .cancel"))
        #expect(source.contains(".diagramScrollZoom { steps in"))
    }
}
#endif

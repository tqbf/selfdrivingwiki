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
        #expect(source.contains("showsControls: !isEditing"))
        #expect(source.contains("SourceRendererPresentationPlanner.isHTMLSource(file)"))
        #expect(source.contains("refreshRendererPresentation"))

        // Source readers must use the same renderer composition as page
        // readers. Both markdown paths (HEAD and native source content) need
        // the installed-package factory and its validated input snapshot so
        // inline attachments do not silently fall back to the host-only
        // default resolver.
        #expect(source.components(separatedBy: "RendererInlineAttachmentResolverFactory.make").count - 1 == 2)
        #expect(source.components(separatedBy: "installedRendererFactoryInputs: installedRendererFactoryInputs").count - 1 == 2)

        let sourceRefreshStart = try #require(source.range(of: ".onChange(of: store.sources)"))
        let sourceRefreshEnd = try #require(source[sourceRefreshStart.lowerBound...].range(of: ".background"))
        let sourceRefresh = source[sourceRefreshStart.lowerBound..<sourceRefreshEnd.lowerBound]
        let editingGuard = try #require(sourceRefresh.range(of: "if !isEditing"))
        let refreshCall = try #require(sourceRefresh.range(of: "refreshRendererPresentation()"))
        let editingGuardEnd = try #require(source[editingGuard.lowerBound...].range(of: "\n            }"))
        #expect(editingGuard.lowerBound < refreshCall.lowerBound && refreshCall.lowerBound < editingGuardEnd.lowerBound,
                "A source-list refresh must not recompute renderer presentation from an active editor buffer.")
    }

    @Test func rendererFallbackStaysLiveWithoutOverwritingStoredPresentationOrPreference() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WikiFS/Sources/SourceDetailView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let fallbackStart = try #require(source.range(of: "private func handleRendererFallback"))
        let fallbackEnd = try #require(source[fallbackStart.lowerBound...].range(of: "\n    // MARK:"))
        let fallback = source[fallbackStart.lowerBound..<fallbackEnd.lowerBound]

        #expect(fallback.contains("DebugLog.tabs"))
        #expect(fallback.contains("setRendererSourcePresentation") == false)
        #expect(fallback.contains("removeRendererSourcePreference") == false)
    }

    @Test func sourceSelectionPersistsOnlyPresentationAndPreservesRendererPreference() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let detail = try String(contentsOf: root.appendingPathComponent("Sources/WikiFS/Sources/SourceDetailView.swift"), encoding: .utf8)
        let host = try String(contentsOf: root.appendingPathComponent("Sources/WikiFS/Renderer/RendererHostView.swift"), encoding: .utf8)

        #expect(detail.contains("clearRendererPreference") == false)
        #expect(detail.contains("removeRendererSourcePreference") == false)
        #expect(host.contains("onSourceSelected") == false)
        #expect(host.contains("onPresentationSelected(.source)"))
    }

    @Test func deferredFallbackIsGuardedByTheFailingSourceIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("Sources/WikiFS/Renderer/RendererHostView.swift"), encoding: .utf8)

        #expect(host.contains("let failedSourceID = state.sourceID"))
        #expect(host.contains("shouldApplyDeferredFallback(failedSourceID: failedSourceID, currentState: state)"))
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
        #expect(host.contains("primaryAction:"))
    }

    @Test("Renderer host guards Split with the detail-width contract") func rendererHostGuardsSplitWidth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("Sources/WikiFS/Renderer/RendererHostView.swift"), encoding: .utf8)
        #expect(host.contains("RendererPresentationLayout.supportsSplit(detailWidth: PageEditorMetrics.detailMinWidth)"))
    }
}
#endif

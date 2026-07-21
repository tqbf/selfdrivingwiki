#if os(macOS)
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import WikiFSCore
@testable import WikiFS

/// Integration tests for the `DropLinkTextView` wiring (issue #616).
///
/// The pure formatter correctness is covered by `DroppedLinkFormatterTests`;
/// the parser round-trip by `DroppedLinkRoundTripTests`; the pasteboard
/// encoding by the existing `SidebarDragPasteboardBridgeTests`. This file
/// covers the **wiring in `ScrollableTextEditor`**: the factory returns a
/// `DropLinkTextView` (not a base `NSTextView`), the `sidebarDropBuilder`
/// closure is stored on the textview and produces the right insertion text
/// via `SidebarDropBuilder.insertionText(for:store:)` against a real
/// `WikiStoreModel`, and the **load-bearing divergence from `WikiReaderView`**
/// (Step 2 §(a) of `plans/drag-wikilinks.md`) holds: `registerForDraggedTypes`
/// registers `wikiSidebarItem` ALONGSIDE the inherited text drag types (NOT
/// instead of them), so drag-selected-text-to-move within the editor still
/// works.
///
/// Avoids synthesizing `NSDraggingInfo` (the protocol's `@objc` member set is
/// fiddly to fake reliably in a `swift test` CLI; the load-bearing
/// pasteboard-decode path is already pinned by `SidebarDragPasteboardBridgeTests`,
/// and the insert-at-character-index behavior is NSTextView's existing,
/// Apple-tested mechanism). Instead, these tests drive the seams directly:
///   - the factory's return type,
///   - the closure storage,
///   - the `registeredDraggedTypes` set on a configured textview,
///   - the `SidebarDropBuilder.insertionText(for:store:)` against a real
///     `WikiStoreModel` (the seam the SwiftUI builder closure actually invokes).
///
/// Fast tier: only `SidebarDropBuilderTests` opens a real DB; tagged `.integration`
/// AND excluded from the fast-tier regex per AGENTS.md.
@MainActor
struct DropLinkTextViewDropTests {

    /// Sanity: the factory in `ScrollableTextEditor` was upgraded to return a
    /// `DropLinkTextView` (the subclass that accepts `wikiSidebarItem` drops).
    /// If a future refactor accidentally reverts this to `NSTextView()`, the
    /// sidebar-drop feature would silently stop working — pin it here.
    @Test func makeConfiguredTextView_returnsDropLinkTextView() {
        let tv = ScrollableTextEditor.makeConfiguredTextView(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        #expect(tv is DropLinkTextView)
    }

    /// The `sidebarDropBuilder` closure is storable on the live textview, and
    /// is invoked with the flattened payload list when the drop builder is
    /// called. This is the seam `ScrollableTextEditor.updateNSView` re-wires
    /// on every SwiftUI evaluation — pin that the storage and invocation both
    /// work (so a future refactor that breaks the storage path fails loudly).
    @Test func sidebarDropBuilder_isStoredAndInvoked() {
        let tv = ScrollableTextEditor.makeConfiguredTextView(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        guard let dropTV = tv as? DropLinkTextView else {
            Issue.record("expected DropLinkTextView")
            return
        }
        var invokedPayloads: [SidebarDragPayload] = []
        dropTV.sidebarDropBuilder = { payloads in
            invokedPayloads = payloads
            return "INSERTED"
        }
        let result = dropTV.sidebarDropBuilder?([
            SidebarDragPayload(kind: .page, id: "01HXXXXXXXXXXXXXXXXXXXXXXX"),
        ])
        #expect(result == "INSERTED")
        #expect(invokedPayloads.count == 1)
        #expect(invokedPayloads.first?.kind == .page)
    }

    // MARK: - registerForDraggedTypes divergence from WikiReaderView (load-bearing)

    /// `WikiReaderView.registerForDraggedTypes` forces `wikiSidebarItem`-ONLY.
    /// That's correct for a WKWebView (competes with internal subviews per
    /// #133/#385), but WRONG for a plain `NSTextView` editor — forcing sidebar-
    /// only would remove the text types (`string`, etc.) that power
    /// drag-selected-text-to-move within the editor AND dropping text from
    /// another app. Pin that `DropLinkTextView` registers the sidebar type
    /// ALONGSIDE the inherited text types (the load-bearing divergence from
    /// the reader's pattern).
    @Test func registeredDraggedTypes_includesSidebarTypeAndTextTypes() {
        let tv = ScrollableTextEditor.makeConfiguredTextView(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let sidebarType = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)

        // Simulate the call AppKit makes when the textview becomes "live" in a
        // window: it registers its default text types (e.g. `.string`). My
        // override MUST combine those WITH the sidebar type — NOT replace them
        // with sidebar-only (the WikiReaderView mistake).
        tv.registerForDraggedTypes([.string])

        let registered = Set(tv.registeredDraggedTypes)
        // The sidebar type MUST be there — the override added it.
        #expect(registered.contains(sidebarType))
        // And the caller's text type MUST still be there — the override added
        // the sidebar type ALONGSIDE it, not instead of it. Without this
        // guarantee, drag-selected-text-to-move within the editor silently
        // breaks (the load-bearing Step-2-§(a) divergence).
        #expect(registered.contains(.string))
    }

    /// When `registerForDraggedTypes` is called with extra types, those types
    /// are added ALONGSIDE the sidebar type (the override MUST NOT replace the
    /// caller's types with sidebar-only — that would be a silent regression
    /// for any future caller wanting extra drag types).
    @Test func registerForDraggedTypes_preservesCallerTypesAlongsideSidebar() {
        let tv = ScrollableTextEditor.makeConfiguredTextView(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let sidebarType = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
        let customType = NSPasteboard.PasteboardType("com.test.custom")
        tv.registerForDraggedTypes([customType])
        let registered = Set(tv.registeredDraggedTypes)
        #expect(registered.contains(sidebarType))
        #expect(registered.contains(customType))
    }

    // MARK: - Eager registration when hosted in a window (#616 live-drop fix)

    /// THE regression test for the #616-in-the-app fix. `NSTextView` registers
    /// its drag types *lazily* (only once the user begins dragging selected text
    /// out of it), so a freshly-opened editor that the user never dragged FROM
    /// had ZERO registered dragged types — AppKit never routed a sidebar drag to
    /// it and the drop silently did nothing. `DropLinkTextView.viewDidMoveToWindow`
    /// eagerly registers the sidebar type so the editor is a live drop target the
    /// moment it appears. Pin that: put the view in a window WITHOUT ever making
    /// it first responder or calling `registerForDraggedTypes` by hand, and the
    /// sidebar type must already be registered.
    @Test func viewDidMoveToWindow_eagerlyRegistersSidebarType() {
        let tv = ScrollableTextEditor.makeConfiguredTextView(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let sidebarType = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)

        // Before entering a window, NSTextView has not lazily registered its
        // drag types — the sidebar type is NOT yet present. (If a future SDK
        // starts eager-registering, this pre-condition may change; the
        // post-condition below is the load-bearing assertion.)
        #expect(!tv.registeredDraggedTypes.contains(sidebarType))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.documentView = tv
        window.contentView = scrollView

        // Placing the view in a window fires `viewDidMoveToWindow`, which must
        // have eagerly registered the sidebar type — WITHOUT the view ever
        // becoming first responder or us calling `registerForDraggedTypes`.
        #expect(tv.registeredDraggedTypes.contains(sidebarType))
    }
}

/// Tests for the store-side builder (`SidebarDropBuilder.insertionText`) — the
/// closure `PageDetailView` and `SourceDetailView` hand to
/// `ScrollableTextEditor.sidebarDropBuilder`. The builder is the seam that
/// resolves display names via `WikiStoreModel.resolveAttachmentName`, routes
/// single-vs-list, and guards on `agentRunCount`.
///
/// Opens a real SQLite wiki via `GRDBWikiStore` (same pattern as
/// `ExternalWriteBookmarkRefreshTests`); tagged `.integration` AND listed in
/// the fast-tier `--skip` regex in `.github/workflows/ci.yml` so it runs only
/// in the `swift-integration` job.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct SidebarDropBuilderIntegrationTests {

    /// Resolve a fresh in-memory store + `WikiStoreModel`. Mirrors
    /// `ExternalWriteBookmarkRefreshTests.makeModel` setup (but in-memory —
    /// issue #651).
    private func makeModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let store = try TestStoreFactory.inMemory()
        store.eventBus = WikiEventBus(wikiID: "test")
        return (WikiStoreModel(store: store), store)
    }

    /// A page drop resolves the page's title via `store.resolveAttachmentName`
    /// and emits `[[page:<ULID>|<Title>]]`. Creates one page, then drops a
    /// payload pointing at it.
    @Test func pageDrop_resolvesTitleAndEmitsCanonicalLink() throws {
        let (model, _) = try makeModel()
        model.newPage(title: "Home Page")
        guard case .page(let pageID) = model.selection else {
            Issue.record("expected page selection after newPage")
            return
        }
        // `WikiStoreModel.newPage` writes via the store and relies on the event
        // bus to fire `reloadFromStore` asynchronously; in a synchronous test
        // with no run-loop pumped, `summaries` is still empty so
        // `resolveAttachmentName` returns nil. Force a synchronous reload so
        // the alias lookup can find the just-created page (matches the test
        // pattern in `ExternalWriteBookmarkRefreshTests`).
        model.reloadSummaries()

        let payload = SidebarDragPayload(kind: .page, id: pageID.rawValue)
        let out = SidebarDropBuilder.insertionText(for: [payload], store: model)
        #expect(out == "[[page:\(pageID.rawValue)|Home Page]]")
    }

    /// A multi-payload drop emits a flat depth-0 markdown list (the v1 Option-B
    /// shape — `plans/drag-wikilinks.md` Step 3). The folder's leaf list is
    /// already flat when it arrives (no depth info survives the pasteboard),
    /// so each `- [[…]]` line is at depth 0.
    @Test func multiPayloadDrop_emitsFlatDepth0MarkdownList() throws {
        let (model, _) = try makeModel()
        model.newPage(title: "Alpha")
        guard case .page(let pageA) = model.selection else {
            Issue.record("expected page selection after newPage")
            return
        }
        model.newPage(title: "Beta")
        guard case .page(let pageB) = model.selection else {
            Issue.record("expected page selection after newPage (2)")
            return
        }
        // Same async-reload gap as `pageDrop_resolvesTitleAndEmitsCanonicalLink` —
        // force `summaries` to reflect both new pages so the alias resolution
        // finds them.
        model.reloadSummaries()

        let payloads = [
            SidebarDragPayload(kind: .page, id: pageA.rawValue),
            SidebarDragPayload(kind: .page, id: pageB.rawValue),
        ]
        let out = SidebarDropBuilder.insertionText(for: payloads, store: model)
        let expected = """
        - [[page:\(pageA.rawValue)|Alpha]]
        - [[page:\(pageB.rawValue)|Beta]]
        """
        #expect(out == expected)
    }

    /// A stale target (deleted page → `resolveAttachmentName` returns nil →
    /// alias falls back to the raw ULID). The link is still canonical and
    /// resolves by id at render; the editor surface doesn't crash or refuse.
    @Test func staleTarget_emitsLinkWithULIDAsAlias() throws {
        let (model, _) = try makeModel()
        // No page exists at this id — the resolution path returns nil.
        let ulid = ULID.generate()
        let payload = SidebarDragPayload(kind: .page, id: ulid)
        let out = SidebarDropBuilder.insertionText(for: [payload], store: model)
        // Alias falls back to the raw ULID.
        #expect(out == "[[page:\(ulid)|\(ulid)]]")
    }

    /// An empty payload list (an empty bookmark folder) is rejected without
    /// dirtying the editor — `insertionText` returns nil.
    @Test func emptyPayloadList_isRejected() throws {
        let (model, _) = try makeModel()
        let out = SidebarDropBuilder.insertionText(for: [], store: model)
        #expect(out == nil)
    }

    /// `linkType(for:)` is the 1:1 inverse of `BookmarksOutlineView.dragKind(for:)`
    /// — the sidebar payload kind maps to the parser's link type in both
    /// directions. Pin the parity so adding a new kind to either side fails
    /// closed at compile time.
    @Test func linkType_isOneToOneWithSidebarDragPayloadKind() {
        #expect(SidebarDropBuilder.linkType(for: .page) == .page)
        #expect(SidebarDropBuilder.linkType(for: .source) == .source)
        #expect(SidebarDropBuilder.linkType(for: .chat) == .chat)
        // Round-trips via rawValue (both enums share "page"/"source"/"chat"
        // as rawValues) — this guards against a future case being added to one
        // side without the other.
        #expect(ParsedLink.LinkType(rawValue: SidebarDragPayload.Kind.page.rawValue) == .page)
        #expect(ParsedLink.LinkType(rawValue: SidebarDragPayload.Kind.source.rawValue) == .source)
        #expect(ParsedLink.LinkType(rawValue: SidebarDragPayload.Kind.chat.rawValue) == .chat)
    }
}
#endif

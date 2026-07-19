import AppKit
import UniformTypeIdentifiers
import WikiFSCore

/// An `NSTextView` subclass that accepts `wikiSidebarItem` drops from the sidebar
/// (a Page, Source, Chat, or a Bookmark folder's leaf list) and inserts a
/// canonical wikilink (`[[page:<ULID>|<alias>]]` etc.) at the **visual drop
/// point** — powering issue #616 (drag sidebar items into the editor).
///
/// Mirrors `WikiReaderView`'s drop pattern (`Reader/WikiReaderView.swift:384-416`)
/// with ONE critical divergence: `registerForDraggedTypes` registers the sidebar
/// type **alongside** the inherited text drag types (NOT instead of them).
///
/// The reader is a `WKWebView` subclass — WebKit manages its own web-content
/// drag/dnd internally, and a `public.data`-conforming sidebar payload would be
/// intercepted by competing subviews (#133/#385), so the reader forces
/// `wikiSidebarItem`-only. The editor is a plain `NSTextView` with no webview
/// child below it, so the competing-subview concern does NOT apply — and forcing
/// `wikiSidebarItem`-only WOULD remove the text types (`string`/`RTF`/`filenames`)
/// that power (a) drag-selected-text-to-move within the editor and (b) dropping
/// text from another doc/app, both of which are load-bearing editor UX. So we
/// register the sidebar type ALONGSIDE the inherited text types.
///
/// The actual link-string building (display-name resolution, single-vs-list
/// routing, agent-run guard) is owned by an injected `sidebarDropBuilder`
/// closure — kept out of the AppKit subclass so the pure
/// `DroppedLinkFormatter` and the store-touching builder are independently
/// testable. The subclass only: (1) reads payloads off the pasteboard,
/// (2) hands them to the builder, (3) inserts the returned text at the drop
/// character index (which fires `textDidChange` → the SwiftUI `@Binding` updates
/// → `store.draftBody`/`editBuffer` dirties, same flow as typing).
final class DropLinkTextView: NSTextView {

    /// Builds the insertion text for a sidebar drop, or returns `nil` to reject
    /// the drop (e.g. when an agent is mid-generation, or the payload is stale).
    /// Receives the flattened payloads across every dragged pasteboard item so
    /// a multi-row sidebar selection or a bookmark folder (both put more than
    /// one item on the pasteboard) is handled uniformly.
    ///
    /// Injected by `ScrollableTextEditor.updateNSView`. The closure captures
    /// `WikiStoreModel` (an `@MainActor` `@Observable`) — AppKit drag callbacks
    /// run on the main thread, so the capture is safe without an actor hop.
    var sidebarDropBuilder: (([SidebarDragPayload]) -> String?)?

    // MARK: - Drag type registration

    /// DIVERGENCE FROM WikiReaderView: do NOT replace with only `wikiSidebarItem`.
    /// The editor is a terminal `NSTextView` with no `WKWebView` child below
    /// it, so the #133/#385 competing-subview interception concern does NOT
    /// apply here. Register the sidebar type ALONGSIDE whatever text types the
    /// superclass registers, so drag-selected-text-to-move within the editor
    /// and dropping text from another doc/app still work.
    ///
    /// `NSTextView` lazily registers its text drag types when `registerForDraggedTypes`
    /// is first called by AppKit (typically at first responder time); calling
    /// `super.registerForDraggedTypes(newTypes + [sidebar])` preserves whatever
    /// the superclass would have registered and adds the wiki sidebar item.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        let sidebar = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
        // De-dup in case the superclass already lists the sidebar type (it
        // won't, but `NSPasteboard.PasteboardType: Equatable` makes the check
        // cheap and the extra type would be a no-op double-registration anyway).
        var combined = newTypes
        if !combined.contains(sidebar) { combined.append(sidebar) }
        super.registerForDraggedTypes(combined)
    }

    /// Eagerly register the sidebar drag type as soon as the view is placed in a
    /// window.
    ///
    /// ROOT CAUSE of #616-regression: `NSTextView` registers its drag types
    /// *lazily* — and in this SwiftUI-hosted, `drawsBackground = false`
    /// configuration it never calls `registerForDraggedTypes` at all until the
    /// user actually begins dragging *selected text out* of the editor. So a
    /// freshly-opened editor had ZERO registered dragged types, AppKit never
    /// routed a sidebar drag to it (no `draggingEntered`/`performDragOperation`
    /// ever fired), and the drop silently did nothing. Relying on the
    /// `registerForDraggedTypes` override to piggyback on NSTextView's own
    /// registration (see the override above) never worked because that call was
    /// never made.
    ///
    /// Registering here makes the editor a live drop target the moment it
    /// appears, independent of first-responder / text-selection state. The
    /// `registerForDraggedTypes` override still runs (it adds the sidebar type
    /// ALONGSIDE whatever text types NSTextView later registers when the user
    /// drags selected text), so drag-selected-text-to-move within the editor and
    /// text drops from other apps keep working — this just guarantees the
    /// sidebar type is present up front rather than never.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)])
    }

    // MARK: - Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Sidebar drag → report `.copy` (the cursor shows the + glyph). A non-
        // sidebar drag (e.g. selected-text-to-move WITHIN the editor, or a
        // plain text drop from another app) falls through to the superclass's
        // default text-drag behavior by calling super — returning `[]` here
        // WOULD silently disable drag-to-move-selected-text within the editor
        // (a load-bearing UX regression vs the plan's Step 2 §(a) divergence
        // from WikiReaderView). The #133/#385 competing-subview concern does
        // NOT apply here (terminal NSTextView, no WKWebView child below).
        if hasSidebarPayloads(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasSidebarPayloads(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    /// AppKit's drop handshake is `draggingEntered` → `prepareForDragOperation`
    /// → `performDragOperation`. `NSView`'s default `prepareForDragOperation`
    /// returns `true`, but `NSTextView` OVERRIDES it to accept only pasteboards
    /// it can read as native text — and a `wikiSidebarItem` payload conforms to
    /// `public.item` (NOT a text type), so NSTextView's override VETOES the drop
    /// and `performDragOperation` is never called (the drag glyph shows `.copy`
    /// from `draggingEntered`, but the release silently does nothing). Override
    /// to accept sidebar drops explicitly; fall through to `super` for everything
    /// else so NSTextView's own text-drop gating is unchanged.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if hasSidebarPayloads(sender.draggingPasteboard) { return true }
        return super.prepareForDragOperation(sender)
    }

    /// `true` only when the sidebar payloads were decoded AND the builder
    /// produced text to insert. Returning `false` falls through to AppKit's
    /// default handling (so a plain text drag still lands as a text insertion,
    /// and a sidebar drop the builder rejected is silently refused without
    /// interfering with anything else).
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payloads = flattenedSidebarPayloads(from: sender.draggingPasteboard),
              let text = sidebarDropBuilder?(payloads) else {
            DebugLog.editor("[drop] editor rejected sidebar drop (no payloads / builder returned nil); falling through to super")
            return super.performDragOperation(sender)
        }
        guard !text.isEmpty else {
            DebugLog.editor("[drop] editor sidebar drop produced empty text; nothing inserted")
            return false
        }

        // Insert at the visual drop point, not necessarily the caret — this
        // matches Finder drag-into-text behavior (where you drop is where it
        // goes). `characterIndexForInsertion(at:)` returns the closest char
        // boundary for the point, clamped to the buffer length.
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let dropChar = characterIndexForInsertion(at: dropPoint)
        let range = NSRange(location: dropChar, length: 0)

        // Route the programmatic insert through the `shouldChangeText` /
        // `didChangeText` bracket — NOT a bare `textStorage.replaceCharacters`.
        // A raw text-storage mutation does NOT post `NSTextDidChangeNotification`,
        // so the `NSTextViewDelegate.textDidChange` never fires, `parent.text`
        // (the SwiftUI `@Binding` → `store.draftBody`) is never updated, and the
        // very next `updateNSView` sees `textView.string != text` and REVERTS
        // the insert back to the stale binding value (the drop appears to do
        // nothing). `didChangeText()` posts the notification (→ binding sync) and
        // `shouldChangeText` registers the edit for undo — the same path a typed
        // edit takes.
        guard shouldChangeText(in: range, replacementString: text) else {
            DebugLog.editor("[drop] editor sidebar drop vetoed by shouldChangeText; nothing inserted")
            return false
        }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()

        // Move the caret to just AFTER the inserted text and reveal it. This is
        // the same outcome as typing the link by hand: caret ends up ready for
        // the next insertion, not stranded at the drop location.
        let caret = dropChar + (text as NSString).length
        setSelectedRange(NSRange(location: caret, length: 0))
        scrollRangeToVisible(NSRange(location: caret, length: 0))

        DebugLog.editor("[drop] editor inserted sidebar drop (chars=\((text as NSString).length), payloads=\(payloads.count))")
        return true
    }

    // MARK: - Pasteboard decoding (mirrors WikiReaderView.sidebarPayloads(from:))

    /// True when at least one `wikiSidebarItem` payload is present on the
    /// pasteboard. Used as a cheap `draggingEntered`/`draggingUpdated` gate so
    /// the cursor shows the `.copy` glyph ONLY for sidebar drags (a plain text
    /// drag still goes through `performDragOperation` and is handled by the
    /// superclass's default text-drop behavior — we DON'T report `.copy` for it
    /// because `NSTextView` already natively accepts text drags without our
    /// intervention).
    private func hasSidebarPayloads(_ pb: NSPasteboard) -> Bool {
        guard let payloads = flattenedSidebarPayloads(from: pb) else { return false }
        return !payloads.isEmpty
    }

    /// Reads every dragged pasteboard item (not just the first — a multi-row
    /// sidebar selection OR a bookmark folder both put more than one item on
    /// the pasteboard) and flattens each item's resolved target list. Returns
    /// `nil` only if no `wikiSidebarItem` data is present at all (a non-sidebar
    /// drag — let AppKit handle it via the superclass). An empty `[...]` (an
    /// empty bookmark folder) is returned as `[]` so the caller can distinguish
    /// "no sidebar data at all" from "sidebar drop with zero targets".
    ///
    /// Decoding errors are logged via `DebugLog.editor` (never bare `try?`)
    /// and treated as no-payloads for that item — a corrupt pasteboard item
    /// shouldn't prevent the rest of a multi-row selection from inserting.
    private func flattenedSidebarPayloads(from pb: NSPasteboard) -> [SidebarDragPayload]? {
        let type = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
        guard let items = pb.pasteboardItems else { return nil }
        var sawAnyData = false
        var payloads: [SidebarDragPayload] = []
        for item in items {
            guard let data = item.data(forType: type) else { continue }
            sawAnyData = true
            do {
                let list = try JSONDecoder().decode(SidebarDragPayloadList.self, from: data)
                payloads.append(contentsOf: list.items)
            } catch {
                DebugLog.editor("[drop] failed decoding sidebar payload JSON: \(error)")
            }
        }
        return sawAnyData ? payloads : nil
    }
}

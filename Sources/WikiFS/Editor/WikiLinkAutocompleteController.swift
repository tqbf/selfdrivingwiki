import AppKit
import WikiFSLinks
import WikiFSSearch

// MARK: - AutocompleteHooks

/// Closures injected by a hosting view (`ChatDetailView` for the composer,
/// `PageDetailView`/`SourceDetailView` for the editor) so the autocomplete
/// controller stays decoupled from `WikiFSCore` (the store handle) and
/// `WikiFSLinks` (the formatter).
///
/// Both are optional — `nil` (when the parent's `autocomplete` returns `nil`,
/// e.g. no Tantivy service attached) means autocomplete is disabled and the
/// host behaves exactly as before.
///
///   - `fetch`: runs the Tantivy `autocomplete(partial:kinds:...)` query for
///     one kind (`[[page:` → `[.page]`, etc.). The controller wraps this in a
///     debounced + cancellable `Task` (AC #5).
///   - `format`: builds the canonical `[[kind:ULID|Title]]` string to insert
///     for a selected hit (`DroppedLinkFormatter.link(for:id:displayName:)`).
///     The controller does the actual range-replace in the text view.
///
/// Lives here at top level (not nested under `ComposerTextView`) so the editor
/// (`ScrollableTextEditor`) and the chat composer (`ComposerTextView`) can
/// share the type. `ComposerTextView.AutocompleteHooks` is a typealias to
/// this so the existing chat-autocomplete tests compile unchanged.
///
/// Intentionally NOT marked `Sendable` — matches the existing chat composer's
/// hooks API exactly so the existing call sites (and tests) compile unchanged.
/// The hooks are owned and called from a `@MainActor`-isolated controller; the
/// debounce `Task` body inherits `@MainActor` isolation from
/// `scheduleAutocomplete`, so the captured hooks don't actually cross actor
/// boundaries.
public struct WikiLinkAutocompleteHooks {
    public let fetch: (String, ParsedLink.LinkType) async -> [TantivyShadowSearchResult]
    public let format: (TantivyShadowSearchResult) -> String

    public init(
        fetch: @escaping (String, ParsedLink.LinkType) async -> [TantivyShadowSearchResult],
        format: @escaping (TantivyShadowSearchResult) -> String
    ) {
        self.fetch = fetch
        self.format = format
    }
}

// MARK: - DebounceHandle

/// Cancellable handle for one scheduled debounce work. Mirrors the
/// `ChangeCoalescer.Handle` pattern
/// (`Sources/WikiFSCore/Store/ChangeCoalescer.swift:23`): the controller cancels
/// the prior handle on each reschedule so only the latest survives.
/// Production's handle calls `task.cancel()`; a test manual scheduler's handle
/// just removes the work from a pending dict.
public final class WikiLinkAutocompleteDebounceHandle {
    let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
}

// MARK: - WikiLinkAutocompleteController

/// Reusable AppKit autocomplete pipeline for `[[kind:partial` wiki-link
/// triggers in an `NSTextView`. Owns the dropdown panel, debounced Tantivy
/// search, arrow-key navigation, and canonical-link insertion.
///
/// Extracted from `ComposerTextView.Coordinator` (issues #436 / #638 / #684)
/// so the chat composer and the page/source editor can share one
/// implementation. The host (`ComposerTextView` or `ScrollableTextEditor`)
/// supplies:
///   - `hooks`: fetch + format closures (decouples the controller from
///     `WikiFSCore` / `DroppedLinkFormatter`).
///   - `debounce` / `scheduleDebounce`: per-keystroke debounce window + an
///     optional seam so tests can drive timing deterministically (issue #661).
///   - `placement`: preferred dropdown direction (`.above` for the chat
///     composer, `.below` for the editor — `#684` added `Placement.below`
///     to `ChatAutocompletePanel` for this).
///   - `widthProvider`: host-specific dropdown width (the composer uses the
///     text view's bounds width; the editor uses the text view's bounds
///     width, clamped to a sane max).
///
/// Per-keystroke flow:
///   1. `textDidChange(textView:)` (called by the host's `NSTextViewDelegate`
///      hook) detects an open `[[kind:partial` trigger via
///      `WikiLinkPrefixScanner` and (re)schedules a debounced fetch.
///   2. The fetch is cancelled + rescheduled on every keystroke (AC #5).
///   3. When results land (and the trigger is still current), the panel is
///      presented at the caret with the configured placement.
///   4. ↑/↓/Escape are consumed by a local `NSEvent` monitor while the panel
///      is up; plain Return invokes `commitAutocomplete()` (the host's
///      `doCommandBy:` routes).
///   5. `commitSelection(_:)` range-replaces the trigger span with the
///      canonical `[[kind:ULID|Title]]` string the `format` closure built,
///      then dismisses the panel.
///
/// `teardown()` (called from the host's `dismantleNSView`) cancels in-flight
/// work, removes the key monitor, and releases the panel so a stale SwiftUI
/// hosting view can't leak across view rebuilds.
@MainActor
final class WikiLinkAutocompleteController {

    // MARK: - Configuration (injected by the host)

    private let hooksProvider: () -> WikiLinkAutocompleteHooks?
    private let debounceProvider: () -> UInt64
    private let scheduleDebounceProvider: ((UInt64, @escaping () async -> Void) -> WikiLinkAutocompleteDebounceHandle?)?
    private let placement: ChatAutocompletePanel.Placement
    private let widthProvider: (NSTextView) -> CGFloat

    // MARK: - Live state

    /// The current dropdown results. Empty when the dropdown is hidden.
    private var autocompleteResults: [TantivyShadowSearchResult] = []
    /// The keyboard-highlighted row in the dropdown. `nil` = nothing
    /// explicitly selected; Enter targets the top row.
    private var selectedIndex: Int? = nil
    /// The trigger for the currently-shown dropdown, kept so a stale
    /// in-flight query that returns after the dropdown was dismissed can
    /// detect it shouldn't apply.
    private var currentTrigger: WikiLinkPrefixScanner.OpenWikiLink? = nil
    /// The non-activating panel hosting the dropdown. Lazily created on
    /// first show; reused across keystrokes.
    private var panel: ChatAutocompletePanel?
    /// The live text view, captured in `textDidChange` so the local event
    /// monitor and the click handler can mutate it without a notification.
    private weak var textView: NSTextView?
    /// Local key monitor (installed while the dropdown is up) — consumes
    /// ↑/↓/Escape. Per reviewer correction #2 (#638): Escape is NOT delivered
    /// via `doCommandBy:`, so a local `NSEvent` monitor is the only path.
    /// Mirrors `OmniboxSearchField.swift:220-226`.
    private var keyMonitor: Any?
    /// The in-flight autocomplete schedule handle. Cancelled and replaced on
    /// every keystroke that lands inside an open-link trigger (AC #5). When
    /// `scheduleDebounceProvider` is nil (production), this is a
    /// `WikiLinkAutocompleteDebounceHandle { task.cancel() }` wrapping a real
    /// `Task.sleep` Task. When a test manual scheduler is injected, this is a
    /// handle that just removes the work from the scheduler's pending dict
    /// (so the work is never run until the test calls `fireAll()`).
    fileprivate var pendingHandle: WikiLinkAutocompleteDebounceHandle?

    init(
        hooksProvider: @escaping () -> WikiLinkAutocompleteHooks?,
        debounceProvider: @escaping () -> UInt64,
        scheduleDebounceProvider: ((UInt64, @escaping () async -> Void) -> WikiLinkAutocompleteDebounceHandle?)? = nil,
        placement: ChatAutocompletePanel.Placement,
        widthProvider: @escaping (NSTextView) -> CGFloat
    ) {
        self.hooksProvider = hooksProvider
        self.debounceProvider = debounceProvider
        self.scheduleDebounceProvider = scheduleDebounceProvider
        self.placement = placement
        self.widthProvider = widthProvider
    }

    /// Whether the autocomplete dropdown is currently showing results. Used
    /// by the host's `doCommandBy:` to decide whether plain Return should
    /// commit the selection (autocomplete open) or fall through to the host's
    /// default Return behavior (composer sends / editor inserts a newline).
    /// Read-only — the controller owns the underlying state.
    var hasResults: Bool { !autocompleteResults.isEmpty }

    // MARK: - Host entry points

    /// Per-keystroke: detect an open `[[kind:partial` trigger at the caret
    /// and (re)schedule a debounced Tantivy query. Dismisses the dropdown
    /// when no trigger is present. Called from the host's
    /// `textDidChange(_:)` delegate hook (after the host has synced its
    /// `@Binding` to the text view's string).
    func textDidChange(textView: NSTextView) {
        self.textView = textView
        evaluateAutocomplete(for: textView)
    }

    /// Decide whether a `doCommandBy:` `insertNewline(_:)` keystroke should be
    /// consumed by the autocomplete (commit the selected row) or fall through
    /// to the host's default Return behavior (the chat composer sends a
    /// message; the editor inserts a literal newline).
    ///
    /// When the dropdown is open AND the keystroke is plain Return (no Shift,
    /// Option, or Command modifier), the controller commits the autocomplete
    /// selection and returns `true` (consumed). Otherwise returns `false` so
    /// the host's normal Return handling runs.
    ///
    /// Mirrors the autocomplete-aware branch of
    /// `ComposerTextView.keyAction(for:modifiers:autocompleteOpen:)` (issues
    /// #436 / #638). The chat composer keeps its own `keyAction` helper that
    /// ALSO distinguishes `.send` (plain Return, dropdown closed) from
    /// `.insertNewline` (Shift/Option+Return) and `.unhandled` (Cmd+Return);
    /// the editor doesn't need that composer-specific shape because plain
    /// Return in the editor just inserts a newline (NSTextView's default).
    @MainActor
    func shouldConsumeReturn(modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !autocompleteResults.isEmpty else { return false }
        let interesting = modifiers.intersection(.deviceIndependentFlagsMask)
        if interesting.contains(.shift) || interesting.contains(.option) || interesting.contains(.command) {
            return false
        }
        commitAutocomplete()
        return true
    }

    /// Final teardown on dismantle: cancel in-flight query, drop the monitor,
    /// close the panel. Distinct from `hideAutocomplete` because we also
    /// want the panel *released* (not just hidden) so a stale SwiftUI
    /// hosting view can't leak across view rebuilds.
    func teardown() {
        pendingHandle?.cancel()
        pendingHandle = nil
        removeKeyMonitor()
        currentTrigger = nil
        autocompleteResults = []
        selectedIndex = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    // MARK: - Autocomplete pipeline

    /// Per-keystroke: detect an open `[[kind:partial` trigger at the caret
    /// and (re)schedule a debounced Tantivy query. Dismisses the dropdown
    /// when no trigger is present.
    private func evaluateAutocomplete(for textView: NSTextView) {
        guard hooksProvider() != nil else { return }
        let caret = textView.selectedRange().location
        let text = textView.string
        // The scanner uses `String.Index` offsets; convert the NSTextView's
        // UTF-16 caret to a Swift `Character`-count offset (the text view
        // stores a UTF-16 string, so for ASCII-only wiki-links the two are
        // equal; for non-ASCII the conversion is still correct because the
        // scanner rebuilds via `Array(text)`).
        let swiftCaret = Self.clampedSwiftOffset(utf16Offset: caret, in: text)
        guard let trigger = WikiLinkPrefixScanner.openLink(at: swiftCaret, in: text) else {
            hideAutocomplete()
            return
        }
        currentTrigger = trigger
        scheduleAutocomplete(trigger: trigger)
    }

    /// Cancel any in-flight query and start a fresh debounced one for
    /// `trigger`. AC #5: typing fast cancels stale in-flight queries.
    ///
    /// Routes the post-debounce work through `scheduleDebounceProvider`
    /// (when injected — tests) or an inline `Task.sleep`-based scheduler
    /// (production / default, kept inline here so the Task body inherits
    /// `@MainActor` from `scheduleAutocomplete` — same as pre-#661). Issue
    /// #661: extracting the debounce sleep into a seam lets tests drive the
    /// timing deterministically with a `ManualScheduler` rather than relying
    /// on `Task.sleep` (which deadlocked CI under heavy integration-tier
    /// load).
    private func scheduleAutocomplete(trigger: WikiLinkPrefixScanner.OpenWikiLink) {
        pendingHandle?.cancel()
        pendingHandle = nil
        guard let hooks = hooksProvider() else { return }
        // Capture the partial at schedule time — a later keystroke that
        // reschedules will see a different trigger and cancel this one
        // before its query lands.
        let partial = trigger.partial
        let kind = trigger.kind
        let debounce = debounceProvider()
        // The post-debounce work: fetch + apply-if-still-current. Shared
        // between the test manual scheduler and the production default.
        // Inherits `@MainActor` from `scheduleAutocomplete` so controller
        // access from inside is isolated.
        let work: () async -> Void = { [weak self] in
            guard let self else { return }
            let results = await hooks.fetch(partial, kind)
            // Only apply if this trigger is still current (a later keystroke
            // may have replaced us and already shown its own results). The
            // MainActor.run hop guarantees self access is isolated
            // regardless of which scheduler ran us.
            await MainActor.run { [weak self] in
                guard let self,
                      self.currentTrigger?.partial == partial,
                      self.currentTrigger?.kind == kind else { return }
                self.applyResults(results)
            }
        }
        if let scheduler = scheduleDebounceProvider {
            // The host may have injected a scheduler (test path: capture for
            // `fireAll()`). The closure returns nil when the host doesn't have
            // a scheduler available THIS pass (e.g. chat composer's
            // `parent.scheduleDebounce` was nil after a SwiftUI rebuild) — in
            // that case, fall through to the production `Task.sleep` path
            // below.
            if let handle = scheduler(debounce, work) {
                pendingHandle = handle
                return
            }
        }
        // Production default: Task.sleep + Task body (inherits
        // `@MainActor` from `scheduleAutocomplete` so controller access
        // from `work` is isolated). Cancelled via task.cancel()
        // — same shape as `WikiChangeBridge.schedule()` at
        // `Sources/WikiFS/Window/WikiChangeBridge.swift:116-122`.
        let task = Task {
            do {
                try await Task.sleep(for: .milliseconds(debounce))
            } catch {
                return  // cancelled during the sleep — bail without applying
            }
            guard !Task.isCancelled else { return }
            await work()
        }
        pendingHandle = WikiLinkAutocompleteDebounceHandle { task.cancel() }
    }

    /// Apply a fresh result set: reset selection, render the panel.
    @MainActor
    private func applyResults(_ results: [TantivyShadowSearchResult]) {
        autocompleteResults = results
        selectedIndex = nil
        if results.isEmpty {
            hideAutocomplete()
        } else {
            presentPanel()
        }
    }

    /// Show (or refresh) the dropdown at the caret. Installs the local
    /// ↑/↓/Escape monitor (reviewer correction #2).
    ///
    /// Positioning (#680): the panel anchors to the **caret line** via
    /// `ChatAutocompletePanel.caretRect(in:)`. Falls back to the text view's
    /// bounds only if `caretRect(in:)` returns nil (live AppKit state not
    /// ready, e.g. no layoutManager). The host passes its preferred
    /// placement (`.above` for the chat composer; `.below` for the editor —
    /// the editor is a tall NSTextView in the middle of the window so there's
    /// more room below the caret than above).
    @MainActor
    private func presentPanel() {
        guard hooksProvider() != nil else { return }
        guard let anchor = self.textView else { return }
        let panel = self.panel ?? ChatAutocompletePanel()
        self.panel = panel
        let width = widthProvider(anchor)
        panel.update(results: autocompleteResults,
                     selectedIndex: selectedIndex,
                     width: width) { [weak self] result in
            MainActor.assumeIsolated {
                self?.commitSelection(result)
            }
        }
        guard let window = anchor.window else {
            // No window yet — can't attach as child. Bail; the next
            // keystroke will retry once the view is in a window.
            return
        }
        // Prefer the caret-line rect; fall back to the text view's bounds
        // if the live AppKit state isn't usable (no layoutManager, no
        // textContainer, empty document with no glyphs). Bounds-based
        // placement still uses the same caret-rect math (so the rect's
        // max/min Y just becomes the view's top/bottom instead of the
        // caret line's), preserving the "just above/below with 4pt gap"
        // behavior.
        let caretRect = ChatAutocompletePanel.caretRect(in: anchor)
            ?? window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.present(caretRect: caretRect, in: window, placement: placement)
        installKeyMonitor()
    }

    func hideAutocomplete() {
        removeKeyMonitor()
        currentTrigger = nil
        autocompleteResults = []
        selectedIndex = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Commit a specific hit (click or Return), then dismiss the dropdown.
    /// Replaces the trigger's `range` with the canonical `[[kind:ULID|Title]]`
    /// string built by the host's `format` closure.
    @MainActor
    private func commitSelection(_ hit: TantivyShadowSearchResult) {
        guard let hooks = hooksProvider(),
              let textView,
              let trigger = currentTrigger else { return }
        let link = hooks.format(hit)
        // Range-replace in the live text view. NSTextView uses UTF-16
        // offsets; `NSRange(_:in:)` converts a `Range<String.Index>` to the
        // matching UTF-16 NSRange against the current string contents.
        let current = textView.string
        let range = NSRange(trigger.range, in: current)
        textView.replaceCharacters(in: range, with: link)
        // Move the caret to just after the inserted `]]`.
        let newCaret = range.location + (link as NSString).length
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        // Sync the host's binding (the host's `textDidChange` would normally
        // do this, but NSTextView's `replaceCharacters` only fires that
        // notification AFTER the run loop spins; the binding must reflect
        // the canonical form synchronously so a follow-up navigation or
        // save sees it). The host catches this via its `textDidChange`
        // hook on the next pass.
        if let hostBinding = self.textBinding {
            hostBinding(textView.string)
        }
        hideAutocomplete()
    }

    /// Optional host-supplied binding sync. The chat composer's coordinator
    /// sets this so the canonical form lands in its `@Binding var text`;
    /// the editor's coordinator sets it to push into `$store.draftBody` /
    /// `$editBuffer`. `nil` is fine — the next `textDidChange` notification
    /// (fired by `replaceCharacters`) lands in the host's delegate and
    /// syncs the binding then. Hook is `@MainActor` because the controller
    /// is `@MainActor`-isolated.
    var textBinding: (@MainActor (String) -> Void)?

    /// Commit the keyboard-selected row (or top row when nothing is
    /// explicitly selected). Called from `shouldConsumeReturn` and (via the
    /// host's `doCommandBy:`) `commitAutocomplete`.
    @MainActor
    func commitAutocomplete() {
        let idx = selectedIndex ?? 0
        guard autocompleteResults.indices.contains(idx) else {
            hideAutocomplete()
            return
        }
        commitSelection(autocompleteResults[idx])
    }

    // MARK: - Local key monitor (↑/↓/Escape — reviewer correction #2)

    /// Installs a local keyDown monitor (idempotent). Removed in
    /// `hideAutocomplete` so the keys fall through to the text view
    /// normally when the dropdown isn't showing. Mirrors
    /// `OmniboxSearchField.swift:220-226`.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleAutocompleteKey(event)
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// Consumes ↑/↓/Escape while the dropdown is showing; passes every
    /// other event through untouched. The monitor is installed only while
    /// the panel is up, so by the time we're here the host text view holds
    /// first responder. Local monitors deliver on the main thread — the
    /// `@MainActor` panel update runs synchronously via
    /// `MainActor.assumeIsolated`.
    private func handleAutocompleteKey(_ event: NSEvent) -> NSEvent? {
        guard !autocompleteResults.isEmpty else { return event }
        switch event.keyCode {
        case 125: // Down arrow
            MainActor.assumeIsolated { self.applyArrow(delta: 1) }
            return nil
        case 126: // Up arrow
            MainActor.assumeIsolated { self.applyArrow(delta: -1) }
            return nil
        case 53: // Escape (reviewer correction #2 — NOT a doCommandBy: selector)
            MainActor.assumeIsolated { self.hideAutocomplete() }
            return nil
        default:
            return event
        }
    }

    @MainActor
    private func applyArrow(delta: Int) {
        guard let next = ChatAutocompleteSelection.advance(
            current: selectedIndex,
            count: autocompleteResults.count,
            delta: delta) else { return }
        selectedIndex = next
        presentPanel()
    }

    // MARK: - Pure helpers (testable)

    /// Pure: map `ParsedLink.LinkType` (the prefix vocabulary — `page:` /
    /// `source:` / `chat:`) → `TantivyDocumentKind` (the search index
    /// vocabulary). Single source of truth so a rename hits both sides.
    /// `nonisolated` for test reach. Mirrors `ChatDetailView.tantivyKind(for:)` so
    /// the editor and the composer route through parallel single sources of
    /// truth (the editor's lives next to its only non-ChatDetailView consumer —
    /// `SidebarDropBuilder.wikiLinkAutocompleteHooks`).
    nonisolated static func tantivyKind(for kind: ParsedLink.LinkType) -> TantivyDocumentKind {
        switch kind {
        case .page:   return .page
        case .source: return .source
        case .chat:   return .chat
        }
    }

    /// Pure inverse of ``tantivyKind(for:)``. Same single-source-of-truth
    /// goal. Named `parsedLinkType(from:)` rather than `linkType(for:)` to
    /// avoid colliding with `SidebarDropBuilder.linkType(for:)` (which maps
    /// from `SidebarDragPayload.Kind` — the two overloads share case names
    /// `.page`/`.source`/`.chat`, so a call site like
    /// `SidebarDropBuilder.linkType(for: .source)` becomes ambiguous when
    /// both overloads exist).
    nonisolated static func parsedLinkType(from kind: TantivyDocumentKind) -> ParsedLink.LinkType {
        switch kind {
        case .page:   return .page
        case .source: return .source
        case .chat:   return .chat
        }
    }

    /// Pure: convert a UTF-16 (NSTextView) caret offset to a Swift
    /// `String.Index`/`Character`-count offset the prefix scanner expects.
    /// Clamps to `[0, text.count]`. The scanner rebuilds via `Array(text)` so
    /// the offset must count `Character`s, not UTF-16 units. ASCII wiki-link
    /// prefixes are BMP-stable so the two are equal for the common case;
    /// non-ASCII is still correct because the scanner handles it on its side.
    nonisolated static func clampedSwiftOffset(utf16Offset: Int, in text: String) -> Int {
        guard utf16Offset > 0 else { return 0 }
        let utf16 = Array(text.utf16)
        guard utf16Offset <= utf16.count else { return text.count }
        let prefix = String(decoding: utf16.prefix(utf16Offset), as: UTF16.self)
        return prefix.count
    }
}

// MARK: - Chat composer back-compat typealiases

extension ComposerTextView {
    /// Back-compat typealias — the chat composer's hooks struct lives at top
    /// level as `WikiLinkAutocompleteHooks` so the editor and the composer
    /// can share the type. Tests that construct `ComposerTextView.AutocompleteHooks(...)`
    /// compile unchanged.
    public typealias AutocompleteHooks = WikiLinkAutocompleteHooks

    /// Back-compat typealias — the debounce handle lives at top level as
    /// `WikiLinkAutocompleteDebounceHandle` so the editor and the composer
    /// share the type. Tests that capture `ComposerTextView.DebounceHandle`
    /// (e.g. `ComposerAutocompleteHostedTests.ManualScheduler.schedule`)
    /// compile unchanged.
    public typealias DebounceHandle = WikiLinkAutocompleteDebounceHandle
}

import AppKit
import SwiftUI
import WikiFSLinks
import WikiFSSearch

/// NSTextView-backed chat composer, replacing the SwiftUI
/// `TextField(..., axis: .vertical).lineLimit(1...6)` that previously backed
/// the chat views' composer.
///
/// Why this exists: on macOS, `TextField` is NSTextField/field-editor backed.
/// Every keystroke, cursor move, or selection change re-lays-out the *entire*
/// string, and `.lineLimit(1...6)` re-measures the full ideal height on every
/// pass. Pasting ~150 lines of markdown into that field beachballed the app.
/// `NSTextView` (the standard Slack/Messages-style chat composer: an
/// `NSScrollView` wrapping a single `NSTextView`, growing 1–6 lines and then
/// scrolling internally) does incremental layout and doesn't re-measure the
/// whole document on every edit.
///
/// Mirrors `OmniboxSearchField.swift` — this repo's existing
/// `NSViewRepresentable` text-input precedent: a `Coordinator` owns delegate
/// state and forwards through to SwiftUI bindings/callbacks; `updateNSView`
/// only touches AppKit state that has actually changed, so it doesn't fight
/// the user's in-flight edit/selection/IME state on every SwiftUI update.
///
/// Placeholder text is intentionally NOT drawn here — `NSTextView` has no
/// built-in placeholder (unlike `NSTextField`/`NSSearchField`), so the caller
/// overlays a SwiftUI `Text` when `text.isEmpty`.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    /// Callers pass `.preferredFont(forTextStyle: .body)` to match the rest of
    /// the composer's type scale.
    let font: NSFont
    /// Invoked when the user presses plain Return (see `keyAction`). Shift+Return
    /// and Option+Return insert a line break instead.
    let onSubmit: () -> Void
    /// Written (asynchronously — never from inside `updateNSView` synchronously)
    /// whenever the measured content height changes. The caller applies
    /// `.frame(height: measuredHeight)`.
    @Binding var measuredHeight: CGFloat
    /// When true, the text view becomes first responder (keyboard focus) once
    /// it's added to a window. Used by ChatView's draft state so the user can
    /// start typing immediately after clicking "Add chat".
    var autoFocus: Bool = false

    // MARK: - Wiki-link autocomplete (#436 / #638)

    /// Optional autocomplete integration. When non-nil, the coordinator runs
    /// a debounced query for each keystroke that lands inside an open
    /// `[[kind:partial` trigger, surfaces the results in a dropdown, and
    /// inserts the canonical `[[kind:ULID|Title]]` form on selection.
    ///
    /// Three injected closures so the AppKit coordinator stays pure about the
    /// engine + formatter (it doesn't import `WikiFSCore` / `DroppedLinkFormatter`
    /// directly — the SwiftUI parent wires those in from `ChatView`):
    ///   - `fetch`: runs the Tantivy `autocomplete(partial:kinds:...)` query.
    ///     Must be async-cancellable on the caller side (the coordinator cancels
    ///     the prior in-flight Task before each new keystroke — AC #5). Returns
    ///     the ranked hits for the dropdown.
    ///   - `format`: builds the canonical `[[kind:ULID|Title]]` string for the
    ///     selected hit (`DroppedLinkFormatter.link(for:id:displayName:)`). The
    ///     coordinator does the actual range-replace in the text view.
    ///   - `geometry`: returns the anchor `NSView` the dropdown should track
    ///     (the composer's text view). Called each time the dropdown is shown.
    var autocomplete: AutocompleteHooks?

    /// Closures injected by `ChatView` so the coordinator stays decoupled from
    /// `WikiFSCore` (the store handle) and `WikiFSLinks` (the formatter). Both
    /// are optional — `nil` means autocomplete is disabled (the composer
    /// behaves exactly as it did before #436). The Coordinator uses its own
    /// captured text view as the dropdown anchor (no closure needed).
    struct AutocompleteHooks {
        /// Runs the Tantivy `autocomplete(partial:kinds:...)` query for one
        /// kind (`[[page:` → `[.page]`, etc.). The coordinator wraps this in a
        /// debounced + cancellable `Task` (AC #5).
        var fetch: (String, ParsedLink.LinkType) async -> [TantivyShadowSearchResult]
        /// Builds the canonical `[[kind:ULID|Title]]` string to insert for a
        /// selected hit. Wraps `DroppedLinkFormatter.link(...)`.
        var format: (TantivyShadowSearchResult) -> String

        init(
            fetch: @escaping (String, ParsedLink.LinkType) async -> [TantivyShadowSearchResult],
            format: @escaping (TantivyShadowSearchResult) -> String
        ) {
            self.fetch = fetch
            self.format = format
        }
    }

    nonisolated static let accessibilityLabel = "Message"
    private let placeholderText = "Ask a question, or ask the Agent to update the wiki…"

    /// Debounce window for the autocomplete query (AC #5). 150 ms is fast
    /// enough to feel instant while keeping per-keystroke Tantivy queries from
    /// stacking up. Sidebar search uses 300 ms; autocomplete feels more
    /// time-critical so it's tighter. This is the canonical production value
    /// (read by ``debounce``'s default). Tests override ``debounce`` to a much
    /// smaller value (e.g. 5 ms) so the schedule/cancel timing is deterministic
    /// without long `Task.sleep` waits — see `ComposerAutocompleteHostedTests`.
    nonisolated static let autocompleteDebounce: UInt64 = 150

    /// Per-instance debounce override (microseconds... no — milliseconds,
    /// matching ``autocompleteDebounce``'s unit). Tests pass a small value
    /// (e.g. 5 ms) so the debounce window is tight and the cancel/collapse
    /// logic is exercised without relying on CI-timing-sensitive `Task.sleep`
    /// tolerances. Production leaves the default (``autocompleteDebounce``).
    /// The coordinator reads this fresh on every schedule.
    var debounce: UInt64 = ComposerTextView.autocompleteDebounce

    /// Cancellable handle for one scheduled debounce work. Mirrors the
    /// `ChangeCoalescer.Handle` pattern (`Sources/WikiFSCore/Store/ChangeCoalescer.swift:23`):
    /// the coordinator cancels the prior handle on each reschedule so only
    /// the latest survives. Production's handle calls `task.cancel()`; a test
    /// manual scheduler's handle just removes the work from a pending dict.
    final class DebounceHandle {
        let cancel: () -> Void
        init(cancel: @escaping () -> Void) { self.cancel = cancel }
    }

    /// Optional debounce scheduler seam (issue #661). When `nil` (default), the
    /// coordinator uses a built-in `Task.sleep`-based scheduler (production
    /// behavior — unchanged from before this seam). Tests inject a manual
    /// scheduler that captures work for an explicit `fireAll()` call so timing
    /// is fully deterministic with no real `Task.sleep`: the prior
    /// `Task.sleep`-based approach deadlocked CI for 6 hours under heavy
    /// integration-tier load because the `@MainActor`-isolated Task bodies
    /// never got scheduled within the polling timeout. Pattern mirrors
    /// `Tests/WikiFSTests/ChangeCoalescerTests.swift`'s `ManualScheduler`.
    var scheduleDebounce: ((UInt64, @escaping () async -> Void) -> DebounceHandle)? = nil

    // MARK: - Height clamping (pure, testable)

    /// Clamp + inset constants. `verticalInsetPerSide` is applied to the text
    /// container's top AND bottom, so the total vertical inset baked into every
    /// height measurement is double this. `verticalInset` is used in the
    /// clamp and the text container's vertical inset, so the two can't drift
    /// apart (the inset is baked into every `contentHeight` measurement fed
    /// into `clampedHeight`, so the clamp's own `+ verticalInset` term has to
    /// match exactly).
    nonisolated enum Metrics {
        static let minLines: CGFloat = 3
        static let maxLines: CGFloat = 6
        static let verticalInsetPerSide: CGFloat = 4
        static var verticalInset: CGFloat { verticalInsetPerSide * 2 }
    }

    /// Pure: clamp measured content height to the 1–6 line band.
    nonisolated static func clampedHeight(contentHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let minHeight = lineHeight * Metrics.minLines + Metrics.verticalInset
        let maxHeight = lineHeight * Metrics.maxLines + Metrics.verticalInset
        return min(max(contentHeight, minHeight), maxHeight)
    }

    /// The one-line height for `font`, used as the initial `@State` value on
    /// the SwiftUI side before any layout pass has run.
    nonisolated static func oneLineHeight(for font: NSFont) -> CGFloat {
        clampedHeight(contentHeight: 0, lineHeight: NSLayoutManager().defaultLineHeight(for: font))
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

    // MARK: - Key handling (pure, testable)

    nonisolated enum ComposerKeyAction {
        case send
        case insertNewline
        case unhandled
        /// Plain Return while the autocomplete dropdown is open with results:
        /// the coordinator should insert the canonical link for the selected
        /// (or top) row and consume the keystroke (no message send).
        case insertAutocomplete
    }

    /// Pure: decide what a `doCommandBy:` selector + the live modifier flags
    /// mean for the composer.
    ///
    /// Plain Return sends. Shift/Option+Return insert a literal line break.
    /// Cmd+Return falls through (`.unhandled`) so the send button's own
    /// `.keyboardShortcut(.return, modifiers: .command)` is the single path —
    /// otherwise a Cmd+Return keystroke would send twice.
    ///
    /// When `autocompleteOpen` is true AND results are present, plain Return
    /// returns `.insertAutocomplete` instead of `.send` so the coordinator
    /// inserts the canonical link rather than sending the message.
    nonisolated static func keyAction(
        for selector: Selector,
        modifiers: NSEvent.ModifierFlags,
        autocompleteOpen: Bool = false
    ) -> ComposerKeyAction {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return .unhandled }
        if modifiers.contains(.shift) || modifiers.contains(.option) { return .insertNewline }
        if modifiers.contains(.command) { return .unhandled }
        return autocompleteOpen ? .insertAutocomplete : .send
    }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Builds and configures the `NSTextView` used both by `makeNSView` and by
    /// tests that need a directly-constructible, fully-configured text view
    /// without going through the SwiftUI representable machinery.
    static func makeConfiguredTextView(font: NSFont) -> NSTextView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: Metrics.verticalInsetPerSide)

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        // Unregister drag types so the NSTextView doesn't intercept sidebar
        // drags routed to the SwiftUI .dropDestination on the composer
        // container. Without this, dragging a page/source/bookmark over the
        // text view (including the placeholder) gets swallowed by AppKit's
        // default text-drag handling and never reaches the composer's
        // dropDestination (issue #385).
        textView.unregisterDraggedTypes()
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            // Zero line-fragment padding so typed text aligns exactly with the
            // SwiftUI placeholder overlay (NSTextContainer defaults to 5pt/side).
            container.lineFragmentPadding = 0
        }

        textView.setAccessibilityLabel(accessibilityLabel)
        return textView
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = Self.makeConfiguredTextView(font: font)
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.string = text
        textView.setAccessibilityPlaceholderValue(placeholderText)
        textView.postsFrameChangedNotifications = true
        context.coordinator.observeFrameChanges(for: textView)

        scrollView.documentView = textView

        if autoFocus {
            DispatchQueue.main.async { [weak scrollView] in
                guard let scrollView,
                      let tv = scrollView.documentView as? NSTextView,
                      tv.window?.firstResponder !== tv else { return }
                tv.window?.makeFirstResponder(tv)
            }
        }
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingFrameChanges()
        coordinator.teardownAutocomplete()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.font != font {
            textView.font = font
        }
        textView.setAccessibilityPlaceholderValue(placeholderText)
        context.coordinator.recomputeHeight(for: textView)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var frameObserver: NSObjectProtocol?
        private var lastObservedWidth: CGFloat?

        // MARK: - Autocomplete state (#436 / #638)

        /// The current dropdown results. Empty when the dropdown is hidden.
        private var autocompleteResults: [TantivyShadowSearchResult] = []
        /// The keyboard-highlighted row in the dropdown. `nil` = nothing
        /// explicitly selected; Enter targets the top row.
        private var selectedIndex: Int? = nil
        /// The trigger for the currently-shown dropdown, kept so a stale
        /// in-flight query that returns after the dropdown was dismissed
        /// can detect it shouldn't apply.
        private var currentTrigger: WikiLinkPrefixScanner.OpenWikiLink? = nil
        /// The non-activating panel hosting the dropdown. Lazily created on
        /// first show; reused across keystrokes.
        private var panel: ChatAutocompletePanel?
        /// The live text view, captured in `textDidChange` so the local event
        /// monitor and the click handler can mutate it without a notification.
        private weak var textView: NSTextView?
        /// Local key monitor (installed while the dropdown is up) — consumes
        /// ↑/↓/Escape. Per reviewer correction #2: Escape is NOT delivered
        /// via `doCommandBy:`, so a local `NSEvent` monitor is the only path.
        /// Mirrors `OmniboxSearchField.swift:242-252`.
        private var keyMonitor: Any?
        /// The in-flight autocomplete schedule handle. Cancelled and replaced on
        /// every keystroke that lands inside an open-link trigger (AC #5). When
        /// `parent.scheduleDebounce` is nil (production), this is a
        /// `DebounceHandle { task.cancel() }` wrapping a real `Task.sleep` Task.
        /// When a test manual scheduler is injected, this is a handle that just
        /// removes the work from the scheduler's pending dict (so the work is
        /// never run until the test calls `fireAll()`).
        fileprivate var pendingHandle: ComposerTextView.DebounceHandle?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.textView = textView
            if parent.text != textView.string {
                parent.text = textView.string
            }
            recomputeHeight(for: textView)
            evaluateAutocomplete(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            self.textView = textView
            let modifiers = (NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
            let open = !autocompleteResults.isEmpty
            switch ComposerTextView.keyAction(for: selector, modifiers: modifiers, autocompleteOpen: open) {
            case .send:
                parent.onSubmit()
                return true
            case .insertAutocomplete:
                // Plain Return while the dropdown is up: insert the selected
                // (or top) row's canonical link and consume. Shift/Option/Cmd
                // still fall through to insert-newline / unhandled via keyAction.
                commitAutocomplete()
                return true
            case .insertNewline, .unhandled:
                return false
            }
        }

        // MARK: - Autocomplete pipeline

        /// Per-keystroke: detect an open `[[kind:partial` trigger at the caret
        /// and (re)schedule a debounced Tantivy query. Dismisses the dropdown
        /// when no trigger is present.
        private func evaluateAutocomplete(for textView: NSTextView) {
            guard parent.autocomplete != nil else { return }
            let caret = textView.selectedRange().location
            let text = textView.string
            // The scanner uses `String.Index` offsets; convert the NSTextView's
            // UTF-16 caret to a Swift `Character`-count offset (the text view
            // stores a UTF-16 string, so for ASCII-only wiki-links the two are
            // equal; for non-ASCII the conversion is still correct because the
            // scanner rebuilds via `Array(text)`).
            let swiftCaret = clampedSwiftOffset(utf16Offset: caret, in: text)
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
        /// Routes the post-debounce work through `parent.scheduleDebounce`
        /// (when injected — tests) or an inline `Task.sleep`-based scheduler
        /// (production / default, kept inline here so the Task body inherits
        /// `@MainActor` from `scheduleAutocomplete` — same as pre-#661). Issue
        /// #661: extracting the debounce sleep into a seam lets tests drive
        /// the timing deterministically with a `ManualScheduler` rather than
        /// relying on `Task.sleep` (which deadlocked CI under heavy
        /// integration-tier load).
        fileprivate func scheduleAutocomplete(trigger: WikiLinkPrefixScanner.OpenWikiLink) {
            pendingHandle?.cancel()
            pendingHandle = nil
            guard let hooks = parent.autocomplete else { return }
            // Capture the partial at schedule time — a later keystroke that
            // reschedules will see a different trigger and cancel this one
            // before its query lands.
            let partial = trigger.partial
            let kind = trigger.kind
            let debounce = parent.debounce
            // The post-debounce work: fetch + apply-if-still-current. Shared
            // between the test manual scheduler and the production default.
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
            if let scheduler = parent.scheduleDebounce {
                // Test path: the manual scheduler captures `work` for an
                // explicit `fireAll()` — no real `Task.sleep`, no Task body
                // scheduling race under load.
                pendingHandle = scheduler(debounce, work)
            } else {
                // Production default: Task.sleep + Task body (inherits
                // `@MainActor` from `scheduleAutocomplete` so coordinator
                // access from `work` is isolated). Cancelled via task.cancel()
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
                pendingHandle = DebounceHandle { task.cancel() }
            }
        }

        /// Apply a fresh result set: reset selection, render the panel. Runs on
        /// the main actor (panel hosting is main-actor-isolated).
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

        /// Show (or refresh) the dropdown above the composer. Installs the
        /// local ↑/↓/Escape monitor (reviewer correction #2).
        @MainActor
        private func presentPanel() {
            guard parent.autocomplete != nil else { return }
            guard let anchor = self.textView else { return }
            let panel = self.panel ?? ChatAutocompletePanel()
            self.panel = panel
            panel.update(results: autocompleteResults,
                         selectedIndex: selectedIndex,
                         width: anchor.bounds.width) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.commitSelection(result)
                }
            }
            panel.present(above: anchor)
            installKeyMonitor()
        }

        @MainActor
        fileprivate func hideAutocomplete() {
            removeKeyMonitor()
            currentTrigger = nil
            autocompleteResults = []
            selectedIndex = nil
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        /// Final teardown on dismantle: cancel in-flight query, drop the monitor,
        /// close the panel. Distinct from `hideAutocomplete` because we also
        /// want the panel *released* (not just hidden) so a stale SwiftUI
        /// hosting view can't leak across view rebuilds.
        @MainActor
        fileprivate func teardownAutocomplete() {
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

        /// Commit a specific hit (click or Return), then dismiss the dropdown.
        /// Replaces the trigger's `range` with the canonical `[[kind:ULID|Title]]`
        /// string built by the parent's `format` closure, syncs the SwiftUI
        /// `text` binding, and recomputes height.
        @MainActor
        private func commitSelection(_ hit: TantivyShadowSearchResult) {
            guard let hooks = parent.autocomplete,
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
            // Sync the SwiftUI binding so the model sees the canonical form.
            parent.text = textView.string
            recomputeHeight(for: textView)
            hideAutocomplete()
        }

        /// Commit the keyboard-selected row (or top row when nothing is
        /// explicitly selected). Called from `doCommandBy:` `.insertAutocomplete`.
        @MainActor
        fileprivate func commitAutocomplete() {
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
        /// the panel is up, so by the time we're here the composer text view
        /// holds first responder. Local monitors deliver on the main thread —
        /// the `@MainActor` panel update runs synchronously via
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

        /// Measures content height and writes the clamped result back to the
        /// binding — deferred to the next main-actor turn (must never write
        /// synchronously, since this also runs from inside `updateNSView`).
        func recomputeHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let contentHeight = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
            let lineHeight = layoutManager.defaultLineHeight(for: parent.font)
            let clamped = ComposerTextView.clampedHeight(contentHeight: contentHeight, lineHeight: lineHeight)
            guard clamped != parent.measuredHeight else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.parent.measuredHeight = clamped
            }
        }

        func observeFrameChanges(for textView: NSTextView) {
            guard frameObserver == nil else { return }
            lastObservedWidth = textView.frame.width
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                MainActor.assumeIsolated {
                    self.handleFrameChange(for: textView)
                }
            }
        }

        func stopObservingFrameChanges() {
            guard let frameObserver else { return }
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }

        @MainActor
        private func handleFrameChange(for textView: NSTextView) {
            let width = textView.frame.width
            guard width != lastObservedWidth else { return }
            lastObservedWidth = width
            recomputeHeight(for: textView)
        }
    }
}

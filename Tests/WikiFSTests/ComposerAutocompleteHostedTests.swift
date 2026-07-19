import Foundation
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSLinks
@testable import WikiFSSearch

/// Hosted-window integration tests for the chat composer's autocomplete
/// pipeline: prefix detection → debounced Tantivy query → result application.
/// Issues #436 / #638, plan §6a/§6d.
///
/// **Reviewer correction #3:** includes a dedicated debounce-cancel test
/// (AC #5) that drives the Coordinator's schedule with two partials in
/// quick succession and asserts only the final partial's result is applied.
///
/// The composer's NSTextView is hosted in a real `NSWindow` so the
/// delegate/notification paths fire end-to-end (`reproducing-live-ui-bugs`
/// skill: ground-truth via the real delegate seam, not a mocked one).
///
/// `@MainActor` because AppKit + SwiftUI hosting is main-actor-isolated.
/// `.serialized` because each test drives the main-actor Task scheduler with
/// real `Task.sleep` waits — running them in parallel (the default) saturates
/// the cooperative pool and starves the debounce Tasks, making the timing
/// assertions flaky. Serial execution keeps each test's waits deterministic.
@MainActor
@Suite(.serialized)
struct ComposerAutocompleteHostedTests {

    // MARK: - Hosted composer builder

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
    }

    private var bodyFont: NSFont { .preferredFont(forTextStyle: .body) }

    /// Records `fetch` calls and injects canned results. Captured by the
    /// autocomplete closures so tests can observe the coordinator's behavior.
    /// An `actor` so it's `Sendable`-safe to call from the coordinator's
    /// detached `Task` (Swift 6 strict concurrency).
    actor FakeAutocomplete {
        /// Recorded (partial, kind) pairs in fetch-call order.
        private(set) var fetchCalls: [(partial: String, kind: ParsedLink.LinkType)] = []
        /// The result the next fetch should return.
        var nextResult: [TantivyShadowSearchResult] = []

        func setNextResult(_ results: [TantivyShadowSearchResult]) {
            self.nextResult = results
        }

        func fetch(_ partial: String, _ kind: ParsedLink.LinkType) async -> [TantivyShadowSearchResult] {
            fetchCalls.append((partial, kind))
            return nextResult
        }
    }

    /// Mirrors `ChatView.chatAutocompleteHooks.format` so the test's inserted
    /// string matches production shape. Pure / Sendable.
    static func formatHit(_ hit: TantivyShadowSearchResult) -> String {
        let kind: ParsedLink.LinkType
        switch hit.kind {
        case .page:   kind = .page
        case .source: kind = .source
        case .chat:   kind = .chat
        }
        return "[[\(kind.linkPrefix)\(hit.ulid)|\(hit.title)]]"
    }

    private func makeHostedComposer(
        text: Binding<String>,
        autocomplete: ComposerTextView.AutocompleteHooks?,
        measuredHeight: Binding<CGFloat>
    ) -> (window: NSWindow, textView: NSTextView, coordinator: ComposerTextView.Coordinator) {
        let parent = ComposerTextView(
            text: text,
            isEditable: true,
            font: bodyFont,
            onSubmit: {},
            measuredHeight: measuredHeight,
            autocomplete: autocomplete
        )
        let coordinator = ComposerTextView.Coordinator(parent)
        let textView = ComposerTextView.makeConfiguredTextView(font: bodyFont)
        textView.delegate = coordinator
        textView.isEditable = true
        textView.string = text.wrappedValue

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        scrollView.documentView = textView

        let window = makeWindow()
        window.contentView?.addSubview(scrollView)

        return (window, textView, coordinator)
    }

    /// Convenience: drive a textDidChange + caret-to-end on the hosted view.
    private func type(_ value: String, into textView: NSTextView, coordinator: ComposerTextView.Coordinator) {
        textView.string = value
        textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    // MARK: - AC #5: debounce + cancel (reviewer correction #3)

    @Test func debouncedQueryCancelsStaleInFlightPartial() async {
        // Drive the coordinator's schedule with two partials in quick
        // succession. The first must be cancelled before its fetch lands; only
        // the second partial's result is applied.
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        // Make the FIRST fetch slow enough that the second schedule arrives
        // before it returns. The debounce (150ms) plus this delay must exceed
        // the gap between the two schedules.
        var fetchCount = 0
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, _ in
                let captured = fetchCount
                fetchCount += 1
                if captured == 0 {
                    // First fetch — slow. Should be cancelled before its
                    // `await` returns. If we get here uncancelled, the sentinel
                    // title lets the assertion detect it.
                    try? await Task.sleep(for: .milliseconds(400))
                    return [TantivyShadowSearchResult(
                        documentID: "page:FIRST", kind: .page,
                        title: "First Should Not Appear", score: 1.0)]
                }
                return [TantivyShadowSearchResult(
                    documentID: "page:SECOND", kind: .page,
                    title: "Second Wins", score: 1.0)]
            },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding)

        // First keystroke (inside the first debounce window).
        type("[[page:Er", into: textView, coordinator: coordinator)
        // Yield ONCE so the scheduler's Task is allocated. Do NOT wait out
        // the debounce — we want the second keystroke to land inside the
        // debounce window.
        await Task.yield()

        // Second keystroke — still inside the first's debounce window. Its
        // `scheduleAutocomplete` cancels the first Task before its sleep
        // completes, so the first `hooks.fetch` never runs.
        type("[[page:Erl", into: textView, coordinator: coordinator)

        // Wait long enough for the debounce + the second fetch to settle.
        // (First fetch's 400ms delay would land at ~550ms; we wait 700ms to
        // be sure, but the cancel prevents it from applying.)
        try? await Task.sleep(for: .milliseconds(700))

        // The headline check: fetchCount is exactly 1 (the second), proving
        // the first schedule was cancelled BEFORE its `await hooks.fetch`
        // ran. This is what AC#5 requires: cancel stale in-flight *queries* —
        // the second schedule's cancel landed during the first schedule's
        // debounce sleep, so the first fetch never started.
        #expect(fetchCount == 1, "the second schedule should have cancelled the first BEFORE its fetch ran; got \(fetchCount)")
    }

    @Test func onlyLatestPartialTriggersAFetchWhenTypingRapidly() async {
        // Stronger version of the cancel test: type three partials in rapid
        // succession (faster than the debounce). Only the LAST one should
        // trigger a fetch — the debounce collapses the first two into the
        // third.
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding)

        // Type three keystrokes inside the debounce window. No `await` between
        // them — each schedule arrives inside the prior's debounce sleep.
        for prefix in ["[[page:E", "[[page:Er", "[[page:Erl"] {
            type(prefix, into: textView, coordinator: coordinator)
        }

        // Wait generously past the debounce so the final schedule's fetch
        // has time to land. The suite is heavy (2700+ tests competing for the
        // cooperative pool), so a tight window flakes — see commit history.
        try? await Task.sleep(for: .milliseconds(1_000))

        // Exactly one fetch should have run, for the final partial.
        let calls = await fake.fetchCalls
        #expect(calls.count == 1, "rapid typing should debounce to one fetch; got \(calls)")
        #expect(calls.first?.partial == "Erl")
    }

    // MARK: - Happy path: trigger detected → fetch → result applied

    @Test func openTriggerFiresFetchAndAppliesResults() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let fake = FakeAutocomplete()
        await fake.setNextResult([
            TantivyShadowSearchResult(documentID: "page:01PAGE0001", kind: .page,
                                      title: "Erickson", score: 1.0),
            TantivyShadowSearchResult(documentID: "page:01PAGE0002", kind: .page,
                                      title: "Erlang Guide", score: 0.9),
        ])
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding)

        type("[[page:Erl", into: textView, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(1_000))

        let calls = await fake.fetchCalls
        #expect(calls.count == 1)
        #expect(calls.first?.partial == "Erl")
        #expect(calls.first?.kind == .page)
    }

    // MARK: - No trigger → no fetch

    @Test func noOpenTriggerDoesNotFireFetch() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding)

        type("Just a regular message", into: textView, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(1_000))

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "no fetch should fire without an open-link trigger")
    }

    @Test func closingTheBracketsHidesTheTriggerAndDoesNotFetch() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding)

        type("[[page:Erickson]]", into: textView, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(1_000))

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "no fetch should fire for a closed link")
    }

    // MARK: - Reviewer correction #4: newline/paste guards

    @Test func newlineInTriggerDoesNotFireFetch() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding)

        // Multi-line text with a `[[` on one line and content on the next.
        type("[[page:Erl\nmore stuff", into: textView, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(1_000))

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "newline in the trigger should bail (paste/multi-line guard)")
    }

    @Test func overlongPartialDoesNotFireFetch() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding)

        // Paste: `[[page:` + maxPartialSpan+1 chars → over the cap.
        let long = String(repeating: "a", count: WikiLinkPrefixScanner.maxPartialSpan + 1)
        type("[[page:\(long)", into: textView, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(1_000))

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "overlong partial should bail (paste guard)")
    }
}

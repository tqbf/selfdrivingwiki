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
///
/// `.tags(.integration)` because the Task-scheduler timing is not reliable
/// under heavy cooperative-pool load — the suite deadlocked CI for 6 hours
/// when run alongside the full integration tier. The fast CI tier skips it;
/// `swift-integration` runs it (where its serial + polling approach is
/// reliable enough). The deterministic-clock rewrite is tracked as follow-up.
@MainActor
@Suite(.serialized, .tags(.integration))
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
        measuredHeight: Binding<CGFloat>,
        debounce: UInt64 = 5
    ) -> (window: NSWindow, textView: NSTextView, coordinator: ComposerTextView.Coordinator) {
        // `debounce` defaults to 5 ms (vs. the 150 ms production default) so
        // the schedule/cancel timing is deterministic without long `Task.sleep`
        // waits — the suite is heavy (2700+ tests competing for the
        // cooperative pool) and a tight 5 ms debounce window makes the cancel
        // assertion insensitive to pool saturation. Production gets the 150 ms
        // default via `ComposerTextView.debounce`'s default.
        let parent = ComposerTextView(
            text: text,
            isEditable: true,
            font: bodyFont,
            onSubmit: {},
            measuredHeight: measuredHeight,
            autocomplete: autocomplete,
            debounce: debounce
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
        // the second partial's fetch fires.
        //
        // Robustness: under heavy cooperative-pool load (this suite runs
        // alongside 2700+ others), a fixed `Task.sleep` wait can return
        // BEFORE the second schedule's @MainActor-isolated Task body gets a
        // chance to run — which looks like "no fetch ran" (false failure).
        // The poll loop below waits adaptively: it exits as soon as the
        // second partial ("Erl") lands in `fetchCalls`, with a generous 3s
        // ceiling so a slow CI runner still completes.
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let fake = FakeAutocomplete()
        await fake.setNextResult([
            TantivyShadowSearchResult(documentID: "page:01PAGE0001", kind: .page,
                                      title: "Erickson", score: 1.0),
        ])
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
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

        // Poll for the SECOND partial ("Erl") to land in fetchCalls. If the
        // cancel worked, "Erl" is the ONLY entry (the first fetch never
        // ran). If the cancel failed, BOTH "Er" and "Erl" land — the
        // assertion below catches that.
        let calls = await Self.waitForPartial("Erl", in: fake, timeout: .seconds(3))

        // The headline check: exactly one fetch ran, for the SECOND partial.
        // This proves the first schedule was cancelled BEFORE its fetch ran
        // (AC #5: cancel stale in-flight queries — the second schedule's
        // cancel landed during the first schedule's debounce sleep).
        #expect(calls.count == 1, "the second schedule should have cancelled the first BEFORE its fetch ran; got \(calls)")
        #expect(calls.first?.partial == "Erl")
        #expect(calls.first?.kind == .page)
    }

    /// Poll `fake.fetchCalls` until it contains an entry with `partial`, or
    /// `timeout` elapses. Returns the snapshot at exit. Adaptive so the cancel
    /// test doesn't flake under heavy cooperative-pool load (a fixed
    /// `Task.sleep` can return before the @MainActor Task body gets to run).
    private static func waitForPartial(
        _ partial: String,
        in fake: FakeAutocomplete,
        timeout: Duration
    ) async -> [(partial: String, kind: ParsedLink.LinkType)] {
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        var snapshot: [(partial: String, kind: ParsedLink.LinkType)] = []
        while Date() < deadline {
            snapshot = await fake.fetchCalls
            if snapshot.contains(where: { $0.partial == partial }) { return snapshot }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return snapshot
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

        // Poll for the FINAL partial ("Erl") to land — adaptive so the test
        // doesn't flake under heavy cooperative-pool load (a fixed
        // `Task.sleep` can return before the @MainActor Task body runs).
        let calls = await Self.waitForPartial("Erl", in: fake, timeout: .seconds(3))

        // Exactly one fetch should have run, for the final partial.
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
        let calls = await Self.waitForPartial("Erl", in: fake, timeout: .seconds(3))
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
        try? await Task.sleep(for: .milliseconds(500))

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
        try? await Task.sleep(for: .milliseconds(500))

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
        try? await Task.sleep(for: .milliseconds(500))

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
        try? await Task.sleep(for: .milliseconds(500))

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "overlong partial should bail (paste guard)")
    }
}

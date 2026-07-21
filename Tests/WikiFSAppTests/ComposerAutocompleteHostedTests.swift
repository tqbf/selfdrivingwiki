#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSLinks
@testable import WikiFSSearch

/// Deterministic tests for the chat composer's autocomplete pipeline:
/// prefix detection → debounced Tantivy query → result application.
/// Issues #436 / #638, plan §6a/§6d. Issue #661: the prior real-`Task.sleep`
/// approach deadlocked CI under heavy integration-tier load — these tests use
/// an injected `ManualScheduler` (pattern from
/// `Tests/WikiFSTests/ChangeCoalescerTests.swift`) so the coordinator captures
/// the post-debounce work without running it, and the test fires it
/// explicitly via `fireAll()`. No `Task.sleep` anywhere in this file.
///
/// `@MainActor` because AppKit + SwiftUI hosting is main-actor-isolated.
/// `.serialized` because the `ManualScheduler` instances are suite-local —
/// serial keeps each test's state isolated from the next (also it's the
/// natural shape for an actor-driven `fireAll()`).
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
    /// An `actor` so it's `Sendable`-safe to call from the captured work
    /// closure (Swift 6 strict concurrency).
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

    /// Captures scheduled debounce work so the test can fire it on demand —
    /// the same pattern `ChangeCoalescerTests` uses, with one addition: this
    /// is a `@unchecked Sendable` class (crosses isolation boundaries between
    /// the @MainActor test body, the schedule seam closure stored in
    /// ComposerTextView, and the captured async work) with an NSLock guarding
    /// its state. Mirrors `OmniboxSearchField.Coordinator`'s `@unchecked
    /// Sendable` shape for the same reason.
    final class ManualScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int: () async -> Void] = [:]
        private var nextID = 0
        private var _cancelledIDs: [Int] = []

        var pendingCount: Int {
            lock.lock(); defer { lock.unlock() }
            return pending.count
        }

        var cancelledIDs: [Int] {
            lock.lock(); defer { lock.unlock() }
            return _cancelledIDs
        }

        func schedule(_ debounce: UInt64, _ work: @escaping () async -> Void) -> ComposerTextView.DebounceHandle {
            lock.lock()
            let id = nextID
            nextID += 1
            pending[id] = work
            lock.unlock()
            return ComposerTextView.DebounceHandle { [weak self] in
                self?.cancel(id: id)
            }
        }

        private func cancel(id: Int) {
            lock.lock()
            pending[id] = nil
            _cancelledIDs.append(id)
            lock.unlock()
        }

        /// Drain pending work under the lock (sync — `NSLock.unlock()` is
        /// unavailable from async contexts in Swift 6).
        private func drainPending() -> [() async -> Void] {
            lock.lock()
            let items = pending.sorted { $0.key < $1.key }.map(\.value)
            pending.removeAll()
            lock.unlock()
            return items
        }

        /// Fire every still-pending scheduled item (in scheduling order). The
        /// captured work runs to completion (its `await`s resolve).
        func fireAll() async {
            // Drain under the lock so concurrent schedules can't observe
            // half-fired state. Work closures themselves run outside the lock
            // so they can't deadlock against a reschedule.
            let items = drainPending()
            for work in items { await work() }
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
        scheduler: ManualScheduler
    ) -> (window: NSWindow, textView: NSTextView, coordinator: ComposerTextView.Coordinator) {
        // Inject the manual scheduler so the coordinator captures work for
        // `fireAll()` instead of creating a real `Task.sleep` Task. Production
        // leaves `scheduleDebounce = nil` (the default) and gets the inline
        // Task.sleep path.
        let parent = ComposerTextView(
            text: text,
            isEditable: true,
            font: bodyFont,
            onSubmit: {},
            measuredHeight: measuredHeight,
            autocomplete: autocomplete,
            debounce: 150,  // production value — the schedule seam means this is never actually slept
            scheduleDebounce: { _, work in scheduler.schedule(0, work) }
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

    // MARK: - AC #5: debounce + cancel (reviewer correction #3 — now deterministic via #661)

    @Test func debouncedQueryCancelsStaleInFlightPartial() async {
        // Drive the coordinator's schedule with two partials in quick
        // succession. The first must be cancelled before its fetch runs; only
        // the second partial's fetch fires. This was previously flaky under
        // heavy cooperative-pool load (the @MainActor-isolated Task body
        // created by the real Task.sleep scheduler never got scheduled within
        // the polling timeout — see issue #661). The injected `ManualScheduler`
        // makes it fully deterministic: schedule work, cancel, fire.
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let scheduler = ManualScheduler()
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
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding, scheduler: scheduler)

        // First keystroke: schedule #1 is captured in the manual scheduler.
        type("[[page:Er", into: textView, coordinator: coordinator)
        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.cancelledIDs.isEmpty)

        // Second keystroke: cancels #1, schedules #2. No fetch ran yet — the
        // manual scheduler doesn't run work until `fireAll()`.
        type("[[page:Erl", into: textView, coordinator: coordinator)
        #expect(scheduler.pendingCount == 1, "exactly one schedule alive (the second; the first was cancelled)")
        #expect(scheduler.cancelledIDs == [0], "the first schedule was cancelled before its work ran")

        // Fire pending work — only #2's fetch should run because #1 was cancelled.
        await scheduler.fireAll()

        let calls = await fake.fetchCalls
        #expect(calls.count == 1, "the second schedule should have cancelled the first BEFORE its fetch ran; got \(calls)")
        #expect(calls.first?.partial == "Erl")
        #expect(calls.first?.kind == .page)
    }

    @Test func onlyLatestPartialTriggersAFetchWhenTypingRapidly() async {
        // Stronger version of the cancel test: type three partials in rapid
        // succession (faster than the debounce — captured, not run). Only the
        // LAST one should trigger a fetch — the debounce cancels the first two.
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let scheduler = ManualScheduler()
        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding, scheduler: scheduler)

        // Type three keystrokes inside the debounce window. No `await` between
        // them. Each schedule arrives inside the prior's debounce window.
        for prefix in ["[[page:E", "[[page:Er", "[[page:Erl"] {
            type(prefix, into: textView, coordinator: coordinator)
        }

        // Two cancellations (the first two were superseded); one pending.
        #expect(scheduler.cancelledIDs == [0, 1], "the first two schedules were cancelled on reschedule")
        #expect(scheduler.pendingCount == 1, "only the final schedule is alive")

        // Fire pending work — only the final partial's fetch should run.
        await scheduler.fireAll()

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

        let scheduler = ManualScheduler()
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
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding, scheduler: scheduler)

        type("[[page:Erl", into: textView, coordinator: coordinator)
        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.cancelledIDs.isEmpty)

        await scheduler.fireAll()

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

        let scheduler = ManualScheduler()
        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding, scheduler: scheduler)

        // Plain text — no `[[` trigger. Nothing is scheduled.
        type("Just a regular message", into: textView, coordinator: coordinator)
        #expect(scheduler.pendingCount == 0, "no schedule should be created without an open-link trigger")

        await scheduler.fireAll()

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "no fetch should fire without an open-link trigger")
    }

    @Test func closingTheBracketsHidesTheTriggerAndDoesNotFetch() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let scheduler = ManualScheduler()
        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding, scheduler: scheduler)

        type("[[page:Erickson]]", into: textView, coordinator: coordinator)
        #expect(scheduler.pendingCount == 0, "no schedule should be created for a closed link")

        await scheduler.fireAll()

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "no fetch should fire for a closed link")
    }

    // MARK: - Reviewer correction #4: newline/paste guards

    @Test func newlineInTriggerDoesNotFireFetch() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let scheduler = ManualScheduler()
        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding, scheduler: scheduler)

        // Multi-line text with a `[[` on one line and content on the next.
        type("[[page:Erl\nmore stuff", into: textView, coordinator: coordinator)
        #expect(scheduler.pendingCount == 0, "newline in the trigger should bail (paste/multi-line guard)")

        await scheduler.fireAll()

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "newline in the trigger should bail (paste/multi-line guard)")
    }

    @Test func overlongPartialDoesNotFireFetch() async {
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let scheduler = ManualScheduler()
        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding, scheduler: scheduler)

        // Paste: `[[page:` + maxPartialSpan+1 chars → over the cap.
        let long = String(repeating: "a", count: WikiLinkPrefixScanner.maxPartialSpan + 1)
        type("[[page:\(long)", into: textView, coordinator: coordinator)
        #expect(scheduler.pendingCount == 0, "overlong partial should bail (paste guard)")

        await scheduler.fireAll()

        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "overlong partial should bail (paste guard)")
    }

    // MARK: - Schedule-not-fired → no fetch (proves work is captured, not run eagerly)

    @Test func scheduleWithoutFireDoesNotRunFetch() async {
        // The ManualScheduler captures work without running it. So scheduling
        // without firing must NOT call fetch — this is the load-bearing
        // property that makes issue #661's fix deterministic: no real
        // `Task.sleep`, no Task body scheduling race, just capture-and-fire.
        var text = ""
        var measuredHeight: CGFloat = ComposerTextView.oneLineHeight(for: bodyFont)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let heightBinding = Binding(get: { measuredHeight }, set: { measuredHeight = $0 })

        let scheduler = ManualScheduler()
        let fake = FakeAutocomplete()
        let hooks = ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in await fake.fetch(partial, kind) },
            format: Self.formatHit
        )

        let (_, textView, coordinator) = makeHostedComposer(
            text: textBinding, autocomplete: hooks, measuredHeight: heightBinding, scheduler: scheduler)

        type("[[page:Erl", into: textView, coordinator: coordinator)
        #expect(scheduler.pendingCount == 1)
        // No fireAll — fetch must not have run.
        let calls = await fake.fetchCalls
        #expect(calls.isEmpty, "scheduled work must not run until fireAll()")
    }
}
#endif

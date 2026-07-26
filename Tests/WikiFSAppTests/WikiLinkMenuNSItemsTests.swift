#if os(macOS)
import AppKit
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// #925: the "Suggest…" / "Find Similar…" submenu used to be filled by a
/// `DispatchSemaphore` bridge that blocked the main thread (and pinned a
/// cooperative-pool thread) on every right-click. It is now a lazy
/// `NSMenuDelegate` that searches when the submenu opens.
///
/// These tests drive the real `NSMenu`/`NSMenuItem` objects through the
/// injected-search seam, so they cover construction, the open callback, the
/// ranked/empty completions, and stale completion after a close. Waiting is
/// condition-based (`Task.yield()` until the probe records a call) or a direct
/// `await` on the loader's task — never a sleep or a wall-clock assertion.
@MainActor
struct WikiLinkMenuNSItemsTests {

    // MARK: - Fixtures

    private static func page(_ title: String, id: String) -> WikiPageSummary {
        WikiPageSummary(id: PageID(rawValue: id), title: title, updatedAt: .now, createdAt: .now)
    }

    /// Records every search the loader starts and holds the result until the
    /// test releases it, so "is the placeholder still up?" is decidable without
    /// racing the scheduler.
    @MainActor
    private final class SearchProbe {
        private(set) var calls: [(query: String, limit: Int)] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var isOpen = false
        var result: [WikiPageSummary] = []

        /// Matches `SimilarPagesMenuLoader.Search`.
        func search(_ query: String, _ limit: Int) async -> [WikiPageSummary] {
            calls.append((query: query, limit: limit))
            if !isOpen {
                await withCheckedContinuation { gate = $0 }
            }
            return result
        }

        /// Lets the pending (and every future) search return.
        func release() {
            isOpen = true
            gate?.resume()
            gate = nil
        }
    }

    /// A loader that is open (never gated) and answers with `results`.
    private func openItem(
        title: String = "Find Similar…",
        query: String = "Alpha",
        results: [WikiPageSummary] = [],
        navigate: @escaping SimilarPagesMenuLoader.Navigate = { _ in }
    ) -> (item: NSMenuItem, probe: SearchProbe) {
        let probe = SearchProbe()
        probe.result = results
        probe.release()
        let item = WikiLinkMenuNSItems.similarPagesItem(
            title: title, query: query,
            search: { q, l in await probe.search(q, l) },
            navigate: navigate)
        return (item, probe)
    }

    private func loader(of item: NSMenuItem) throws -> SimilarPagesMenuLoader {
        try #require(item.representedObject as? SimilarPagesMenuLoader)
    }

    /// Condition-based wait: yields the main actor until `condition` holds.
    /// Bounded so a genuine hang fails the test instead of spinning forever.
    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Construction (AC.7)

    @Test func menuConstructionReturnsSearchingPlaceholder() throws {
        let (item, probe) = openItem(query: "Alpha")
        let submenu = try #require(item.submenu)

        #expect(item.title == "Find Similar…")
        #expect(submenu.items.count == 1)
        #expect(submenu.items.first?.title == "Searching…")
        #expect(submenu.items.first?.isEnabled == false)
        // The whole point of #925: building the context menu does no searching.
        #expect(probe.calls.isEmpty)
        #expect(submenu.delegate is SimilarPagesMenuLoader)
    }

    @Test func emptyQueryShowsNoSimilarPagesWithoutSearching() {
        let (item, probe) = openItem(query: "")
        #expect(item.submenu?.items.map(\.title) == ["No similar pages"])
        #expect(item.submenu?.items.first?.isEnabled == false)
        #expect(probe.calls.isEmpty)
        // No loader is attached at all — there is nothing to search.
        #expect(item.representedObject == nil)
        #expect(item.submenu?.delegate == nil)
    }

    // MARK: - Opening (AC.8)

    @Test func openingSubmenuStartsOneSearch() async throws {
        let (item, probe) = openItem(query: "Alpha", results: [Self.page("Beta", id: "01B")])
        let submenu = try #require(item.submenu)
        let loader = try loader(of: item)

        // AppKit can call `menuNeedsUpdate(_:)` more than once per display pass.
        loader.menuNeedsUpdate(submenu)
        loader.menuNeedsUpdate(submenu)
        loader.menuNeedsUpdate(submenu)
        await loader.inFlightSearch?.value

        #expect(probe.calls.count == 1)
        #expect(probe.calls.first?.query == "Alpha")
        #expect(probe.calls.first?.limit == 8)

        // Reopening an already-filled submenu does not search again either.
        loader.menuNeedsUpdate(submenu)
        #expect(probe.calls.count == 1)
    }

    @Test func rankedResultsReplacePlaceholderAndNavigate() async throws {
        let ranked = [
            Self.page("First", id: "01A"),
            Self.page("Second", id: "01B"),
            Self.page("Third", id: "01C"),
        ]
        let navigated = Navigated()
        let (item, _) = openItem(query: "Alpha", results: ranked, navigate: { navigated.ids.append($0.id) })
        let submenu = try #require(item.submenu)
        let loader = try loader(of: item)

        loader.menuNeedsUpdate(submenu)
        await loader.inFlightSearch?.value

        // Rank order is the search's, verbatim — no placeholder left behind.
        #expect(submenu.items.map(\.title) == ["First", "Second", "Third"])

        let second = try #require(submenu.items.dropFirst().first)
        let target = try #require(second.target)
        let action = try #require(second.action)
        _ = target.perform(action)
        #expect(navigated.ids == [PageID(rawValue: "01B")])
    }

    @Test func emptyResultsShowNoSimilarPages() async throws {
        let (item, _) = openItem(query: "Alpha", results: [])
        let submenu = try #require(item.submenu)
        let loader = try loader(of: item)

        loader.menuNeedsUpdate(submenu)
        await loader.inFlightSearch?.value

        #expect(submenu.items.map(\.title) == ["No similar pages"])
        #expect(submenu.items.first?.isEnabled == false)
    }

    @Test func cancelledOrClosedMenuIgnoresStaleCompletion() async throws {
        let probe = SearchProbe()
        probe.result = [Self.page("First", id: "01A")]
        let navigated = Navigated()
        let item = WikiLinkMenuNSItems.similarPagesItem(
            title: "Suggest…", query: "Alpha",
            search: { q, l in await probe.search(q, l) },
            navigate: { navigated.ids.append($0.id) })
        let submenu = try #require(item.submenu)
        let loader = try loader(of: item)

        loader.menuNeedsUpdate(submenu)
        await yieldUntil { probe.calls.count == 1 }
        // Hold the handle the loader is about to drop, so the stale completion
        // is awaitable rather than merely "probably done by now".
        let stale = try #require(loader.inFlightSearch)

        loader.menuDidClose(submenu)
        #expect(stale.isCancelled)

        probe.release()
        await stale.value

        // The dismissed submenu was not mutated by the late result.
        #expect(submenu.items.map(\.title) == ["Searching…"])
        #expect(navigated.ids.isEmpty)

        // Reopening retries from the placeholder and completes normally — the
        // stale completion did not leave the loader wedged or double-complete.
        loader.menuNeedsUpdate(submenu)
        await loader.inFlightSearch?.value
        #expect(probe.calls.count == 2)
        #expect(submenu.items.map(\.title) == ["First"])
    }

    // MARK: - Source guard (AC.7)

    @Test func wikiStoreModelHasNoSynchronousTantivyBridge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = root.appending(path: "Sources/WikiFSCore/Store/WikiStoreModel.swift")
        let text = try String(contentsOf: model, encoding: .utf8)

        // Doc/comment lines are excluded so the #925 rationale can name the
        // removed symbols in prose without tripping its own guard.
        let banned = ["resolveTantivyLegSync", "TantivyLegBox", "DispatchSemaphore", "semaphore.wait"]
        var offenders: [String] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            for symbol in banned where trimmed.contains(symbol) {
                offenders.append("WikiStoreModel.swift:\(i + 1): \(symbol)")
            }
        }
        #expect(offenders.isEmpty, "#925: synchronous Tantivy bridge reappeared — \(offenders)")
    }

    /// Main-actor recorder for the navigate closure. A plain `var` captured by
    /// an escaping `@MainActor` closure would need `inout`; a reference type is
    /// the straightforward way to observe the call.
    @MainActor
    private final class Navigated {
        var ids: [PageID] = []
    }
}
#endif

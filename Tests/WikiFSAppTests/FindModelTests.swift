#if os(macOS)
import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// `FindModel` is the shared find-bar state that BOTH Cmd+F (in the detail
/// views) and the address bar's "Find on Page…" menu item now drive (issue
/// #157). These tests pin down the toggle / search / navigation contract those
/// two entry points rely on, independent of any SwiftUI wiring.
@MainActor
@Suite struct FindModelTests {

    // MARK: - Toggle (the action both entry points call)

    @Test func toggleOpensAndRunsFindWhenContentPresent() {
        let model = FindModel()
        model.content = "hello world hello"

        // Closed by default.
        #expect(model.isShowing == false)

        model.query = "hello"
        model.toggle()
        #expect(model.isShowing == true)
        // Toggling open runs the search immediately (FindModel.toggle contract).
        #expect(model.matches.count == 2)
        #expect(model.currentMatchIndex == 1)
    }

    @Test func toggleClosesAndClearsOnSecondToggle() {
        let model = FindModel()
        model.content = "abc abc"
        model.query = "abc"
        model.toggle() // open
        #expect(model.isShowing == true)
        #expect(model.matches.count == 2)

        model.toggle() // close
        #expect(model.isShowing == false)
        // Closing clears matches so no stale highlighting lingers.
        #expect(model.matches.isEmpty)
        #expect(model.currentMatchIndex == 0)
    }

    @Test func toggleIsANoopWhenThereIsNoContent() {
        let model = FindModel()
        // No content set.
        model.query = "anything"
        model.toggle()
        #expect(model.isShowing == true)
        #expect(model.matches.isEmpty)
        #expect(model.currentMatchIndex == 0)
    }

    // MARK: - Search semantics

    @Test func searchIsCaseInsensitiveByDefault() {
        let model = FindModel()
        model.content = "Foo foo FOO"
        model.query = "foo"
        model.search()
        #expect(model.matches.count == 3)
    }

    @Test func searchRespectsCaseSensitiveToggle() {
        let model = FindModel()
        model.content = "Foo foo FOO"
        model.caseSensitive = true
        model.query = "foo"
        model.search()
        #expect(model.matches.count == 1)
    }

    @Test func emptyQueryYieldsNoMatches() {
        let model = FindModel()
        model.content = "some content"
        model.query = ""
        model.search()
        #expect(model.matches.isEmpty)
        #expect(model.currentMatchIndex == 0)
    }

    @Test func noContentYieldsNoMatchesEvenWithQuery() {
        let model = FindModel()
        model.content = nil
        model.query = "x"
        model.search()
        #expect(model.matches.isEmpty)
    }

    // MARK: - Next / previous navigation

    @Test func nextMatchWrapsAround() {
        let model = FindModel()
        model.content = "a a a"
        model.query = "a"
        model.search() // 3 matches, index 1
        #expect(model.currentMatchIndex == 1)

        model.nextMatch()
        #expect(model.currentMatchIndex == 2)
        model.nextMatch()
        #expect(model.currentMatchIndex == 3)
        // Wraps from last back to first.
        model.nextMatch()
        #expect(model.currentMatchIndex == 1)
    }

    @Test func previousMatchWrapsAround() {
        let model = FindModel()
        model.content = "a a a"
        model.query = "a"
        model.search() // index 1
        // Wraps from first back to last.
        model.previousMatch()
        #expect(model.currentMatchIndex == 3)
        model.previousMatch()
        #expect(model.currentMatchIndex == 2)
    }

    @Test func navigationIsNoopWithNoMatches() {
        let model = FindModel()
        model.content = "abc"
        model.query = "zzz"
        model.search()
        model.nextMatch()
        model.previousMatch()
        #expect(model.currentMatchIndex == 0)
    }

    // MARK: - Navigation callback

    @Test func toggleNotifiesCurrentMatchViaCallback() {
        let model = FindModel()
        model.content = "x y x"
        model.query = "x"

        var visited: [String] = []
        model.onNavigateToMatch = { range in
            visited.append(String(model.content![range]))
        }

        model.toggle() // open -> match 1
        #expect(visited == ["x"])
        model.nextMatch() // -> match 2
        #expect(visited == ["x", "x"])
    }

    // MARK: - Count label

    @Test func countLabelFormats() {
        let model = FindModel()
        #expect(model.countLabel == "") // empty query

        model.query = "q"
        model.content = "q q q"
        model.search()
        #expect(model.countLabel == "1 of 3")

        model.content = "no match here"
        model.search()
        #expect(model.countLabel == "0 matches")
    }

    // MARK: - Dismiss

    @Test func dismissHidesAndClears() {
        let model = FindModel()
        model.content = "abc"
        model.query = "a"
        model.toggle()
        #expect(model.isShowing == true)

        model.dismiss()
        #expect(model.isShowing == false)
        #expect(model.matches.isEmpty)
        #expect(model.currentMatchIndex == 0)
    }
}
#endif

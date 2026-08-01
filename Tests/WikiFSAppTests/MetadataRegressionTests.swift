import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

@MainActor
struct MetadataRegressionTests {
    @Test func pageCompareActionOpensExistingWindow() throws {
        var opened = false
        let router = router(comparePage: { _ in opened = true; return true })
        try router.route(action: .comparePageVersions(PageID(rawValue: "page")))
        #expect(opened)
    }

    @Test func sourceCompareActionOpensExistingSheet() throws {
        var opened = false
        let router = router(compareSource: { _ in opened = true; return true })
        try router.route(action: .compareSourceExtractions(SourceID(rawValue: "source")))
        #expect(opened)
    }

    @Test func historyTabKeepsChronologyAndNavigation() {
        #expect(InspectorTab.normalizedFallback(selection: .history, availableTabs: [.metadata, .outline, .history]) == .history)
    }

    @Test func outlineTabKeepsExistingContent() {
        #expect(InspectorTab.normalizedFallback(selection: .outline, availableTabs: [.metadata, .outline]) == .outline)
    }

    private func router(comparePage: @escaping (PageID) -> Bool = { _ in true }, compareSource: @escaping (SourceID) -> Bool = { _ in true }) -> MetadataActionRouter {
        .init(openPage: { _ in true }, openSource: { _ in true }, openChat: { _ in true }, selectActivity: { _ in true }, comparePageVersions: comparePage, compareSourceExtractions: compareSource, copy: { _ in true }, openURL: { _ in true })
    }
}

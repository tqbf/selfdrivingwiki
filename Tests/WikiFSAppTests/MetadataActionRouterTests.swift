import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

@MainActor
struct MetadataActionRouterTests {
    @Test func opensTypedPageTarget() throws {
        var opened = false
        let router = router(openPage: { _ in opened = true; return true })
        try router.route(link: .page(PageID(rawValue: "page")))
        #expect(opened)
    }

    @Test func opensTypedSourceTarget() throws {
        var opened: SourceID?
        try router(openSource: { opened = $0; return true }).route(link: .source(SourceID(rawValue: "source")))
        #expect(opened == SourceID(rawValue: "source"))
    }

    @Test func opensTypedChatTarget() throws {
        var opened: ChatID?
        try router(openChat: { opened = $0; return true }).route(link: .chat(ChatID(rawValue: "chat")))
        #expect(opened == ChatID(rawValue: "chat"))
    }

    @Test func selectsExactActivityTarget() throws {
        var opened: QueueItem.ID?
        let id = QueueItem.ID(rawValue: "activity")
        try router(selectActivity: { opened = $0; return true }).route(link: .activity(id))
        #expect(opened == id)
    }

    @Test func opensValidatedURLTarget() throws {
        var opened: URL?
        let url = URL(string: "https://example.com")!
        try router(openURL: { opened = $0; return true }).route(link: .url(url))
        #expect(opened == url)
    }

    @Test func opensPageVersionComparison() throws {
        var opened: PageID?
        try router(comparePageVersions: { opened = $0; return true }).route(action: .comparePageVersions(PageID(rawValue: "page")))
        #expect(opened == PageID(rawValue: "page"))
    }

    @Test func opensSourceExtractionComparison() throws {
        var opened: SourceID?
        try router(compareSourceExtractions: { opened = $0; return true }).route(action: .compareSourceExtractions(SourceID(rawValue: "source")))
        #expect(opened == SourceID(rawValue: "source"))
    }

    @Test func copiesExactIdentifier() throws {
        var copied = ""
        let router = router(copy: { copied = $0; return true })
        try router.route(action: .copyIdentifier("id"))
        #expect(copied == "id")
    }

    @Test func unsafeURLIsRejectedWithoutOpen() {
        var opened = false
        let router = router(openURL: { _ in opened = true; return true })
        #expect(throws: MetadataActionRouterError.unsafeURL(URL(string: "file:///private/test")!)) {
            try router.route(link: .url(URL(string: "file:///private/test")!))
        }
        #expect(!opened)
    }

    @Test func missingSubjectReturnsNoOp() throws {
        let router = router(openPage: { _ in false })
        #expect(throws: MetadataActionRouterError.targetOpenFailed) {
            try router.route(link: .page(PageID(rawValue: "missing")))
        }
    }

    @Test func pageCompareUnavailableReturnsNoOp() {
        #expect(throws: MetadataActionRouterError.targetOpenFailed) {
            try router(comparePageVersions: { _ in false }).route(action: .comparePageVersions(PageID(rawValue: "page")))
        }
    }

    @Test func sourceCompareUnavailableReturnsNoOp() {
        #expect(throws: MetadataActionRouterError.targetOpenFailed) {
            try router(compareSourceExtractions: { _ in false }).route(action: .compareSourceExtractions(SourceID(rawValue: "source")))
        }
    }

    @Test func copyFailureReturnsTypedError() {
        #expect(throws: MetadataActionRouterError.copyFailed) {
            try router(copy: { _ in false }).route(action: .copyIdentifier("id"))
        }
    }

    @Test func targetOpenFailureReturnsTypedError() {
        #expect(throws: MetadataActionRouterError.targetOpenFailed) {
            try router(openURL: { _ in false }).route(link: .url(URL(string: "https://example.com")!))
        }
    }

    @Test func explicitNoOpPerformsNoSideEffect() throws {
        var copied = false
        let router = router(copy: { _ in copied = true; return true })
        try router.route(action: .none)
        #expect(!copied)
    }

    private func router(
        openPage: @escaping (PageID) -> Bool = { _ in true },
        openSource: @escaping (SourceID) -> Bool = { _ in true },
        openChat: @escaping (ChatID) -> Bool = { _ in true },
        selectActivity: @escaping (QueueItem.ID) -> Bool = { _ in true },
        comparePageVersions: @escaping (PageID) -> Bool = { _ in true },
        compareSourceExtractions: @escaping (SourceID) -> Bool = { _ in true },
        copy: @escaping (String) -> Bool = { _ in true },
        openURL: @escaping (URL) -> Bool = { _ in true }
    ) -> MetadataActionRouter {
        .init(
            openPage: openPage,
            openSource: openSource,
            openChat: openChat,
            selectActivity: selectActivity,
            comparePageVersions: comparePageVersions,
            compareSourceExtractions: compareSourceExtractions,
            copy: copy,
            openURL: openURL)
    }
}

import Testing
@testable import WikiFSSearch

@Suite("Embedding bundle selection")
struct EmbeddingBundleTests {
    @Test func appAndDaemonCanHostTheModel() {
        #expect(EmbeddingService.isModelHostBundle(path: "/Applications/WikiFS.app"))
        #expect(EmbeddingService.isModelHostBundle(path: "/Applications/WikiFS.app/Contents/XPCServices/wikid.xpc"))
        #expect(!EmbeddingService.isModelHostBundle(path: "/Applications/WikiFS.app/Contents/Helpers/wikictl"))
    }
}

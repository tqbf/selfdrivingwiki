import Foundation
import Testing
@testable import WikiFSCore

/// Phase 6 — version pinning (`@vN`): @MainActor model plumbing tests.
/// AC.7 — pin producer/consumer: `selectSource(byID:pinnedExtractionID:)` →
/// `pendingPinnedExtraction` → `consumePendingPinnedExtraction(for:)`.
/// Pure model state — no WKWebView needed.
@MainActor
struct Phase6PinningModelTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-phase6-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func makeModel() throws -> (WikiStoreModel, PageID, PageID) {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))
        _ = try store.appendProcessedMarkdown(sourceID: source.id, content: "v1", origin: "t", note: nil)
        _ = try store.appendProcessedMarkdown(sourceID: source.id, content: "v2", origin: "t", note: nil)
        let v3 = try store.appendProcessedMarkdown(sourceID: source.id, content: "v3", origin: "t", note: nil)
        model.reloadFromStore()
        return (model, source.id, v3.id)
    }

    @Test func selectSourceStashesPinnedExtractionTaggedToSelection() throws {
        let (model, sourceID, pinID) = try makeModel()
        let beforeVersion = model.pendingScrollAnchorVersion

        _ = model.selectSource(byID: sourceID, anchor: #""q""#, pinnedExtractionID: pinID)

        // The pin is tagged to the destination selection.
        #expect(model.pendingPinnedExtraction?.versionID == pinID)
        #expect(model.pendingPinnedExtraction?.selection == .source(sourceID))
        // The anchor version bumped (the pin travels with its anchor).
        #expect(model.pendingScrollAnchorVersion == beforeVersion + 1)
    }

    @Test func consumeReturnsIDOnceForMatchingSelection() throws {
        let (model, sourceID, pinID) = try makeModel()
        _ = model.selectSource(byID: sourceID, anchor: #""q""#, pinnedExtractionID: pinID)

        // First consume for the matching selection returns the id.
        #expect(model.consumePendingPinnedExtraction(for: .source(sourceID)) == pinID)
        // State cleared.
        #expect(model.pendingPinnedExtraction == nil)
        // Second consume returns nil (already consumed).
        #expect(model.consumePendingPinnedExtraction(for: .source(sourceID)) == nil)
    }

    @Test func consumeReturnsNilForMismatchedSelection() throws {
        let (model, sourceID, pinID) = try makeModel()
        let otherID = PageID(rawValue: "01JAAAAAAAAAAAAAAAAAAAAAAA")
        _ = model.selectSource(byID: sourceID, anchor: #""q""#, pinnedExtractionID: pinID)

        // Mismatched selection → nil, state preserved.
        #expect(model.consumePendingPinnedExtraction(for: .source(otherID)) == nil)
        #expect(model.pendingPinnedExtraction?.versionID == pinID)
    }

    @Test func consumeReturnsNilForNilSelection() throws {
        let (model, sourceID, pinID) = try makeModel()
        _ = model.selectSource(byID: sourceID, anchor: #""q""#, pinnedExtractionID: pinID)

        #expect(model.consumePendingPinnedExtraction(for: nil) == nil)
    }

    @Test func nilPinIsNoOp() throws {
        let (model, sourceID, _) = try makeModel()

        _ = model.selectSource(byID: sourceID, anchor: nil, pinnedExtractionID: nil)

        // No pending pin state set.
        #expect(model.pendingPinnedExtraction == nil)
    }

    @Test func selectSourceWithoutPinClearsStalePin() throws {
        let (model, sourceID, pinID) = try makeModel()

        // First navigation with a pin.
        _ = model.selectSource(byID: sourceID, anchor: #""q""#, pinnedExtractionID: pinID)
        #expect(model.pendingPinnedExtraction != nil)

        // Second navigation without a pin → no pending pin (cleared).
        _ = model.selectSource(byID: sourceID, anchor: #""q2""#, pinnedExtractionID: nil)
        #expect(model.pendingPinnedExtraction == nil)
    }
}

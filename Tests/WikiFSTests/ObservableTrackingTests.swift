import Testing
import Foundation
import Observation
@testable import WikiFSCore

/// Model-level `@Observable` contract tests.
///
/// These verify that mutating observable properties fires the tracking
/// callback that SwiftUI's runtime relies on to re-render views. They do NOT
/// verify that a specific view reads the property in its body (that was the
/// omnibox bookmark bug — see `SWIFTUI-RULES.md` §3.6), but they lock in the
/// model's half of the contract so a refactor that breaks observation is
/// caught immediately rather than silently making the UI go stale.
@MainActor
struct ObservableTrackingTests {

    /// `withObservationTracking`'s `onChange` closure is `@Sendable`, so a
    /// plain `var` can't be captured. This reference-type box is
    /// `@unchecked Sendable` — safe because the test is single-threaded.
    private final class Box: @unchecked Sendable {
        var fireCount = 0
    }

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("observable-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - bookmarkNodes

    @Test func addPageRefFiresBookmarkNodesObservation() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let page = try await store.createPage(title: "Observable Page")
        let model = WikiStoreModel(store: store)

        let box = Box()
        withObservationTracking {
            _ = model.bookmarkNodes
        } onChange: {
            box.fireCount += 1
        }

        #expect(model.bookmarkNodes.isEmpty)

        await model.addPageRef(parentID: nil, pageID: page.id)
        // The bus delivers reloads async; in tests without a bus, force the
        // synchronous reload so the observation fires and the array is fresh.
        await model.bootstrapFromStore()

        #expect(box.fireCount == 1,
                "addPageRef → reloadBookmarkNodes must fire the @Observable callback")
        #expect(model.bookmarkNodes.count == 1)
    }

    @Test func addSourceRefFiresBookmarkNodesObservation() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let source = try await store.addSource(filename: "paper.pdf", data: Data("x".utf8))
        let model = WikiStoreModel(store: store)

        let box = Box()
        withObservationTracking {
            _ = model.bookmarkNodes
        } onChange: {
            box.fireCount += 1
        }

        await model.addSourceRef(parentID: nil, sourceID: source.id)
        await model.bootstrapFromStore()

        #expect(box.fireCount == 1,
                "addSourceRef → reloadBookmarkNodes must fire the @Observable callback")
        #expect(model.bookmarkNodes.count == 1)
    }

    @Test func createFolderFiresBookmarkNodesObservation() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)

        let box = Box()
        withObservationTracking {
            _ = model.bookmarkNodes
        } onChange: {
            box.fireCount += 1
        }

        _ = await model.createFolder(parentID: nil, name: "Research")
        await model.bootstrapFromStore()

        #expect(box.fireCount == 1,
                "createFolder → reloadBookmarkNodes must fire the @Observable callback")
        #expect(model.bookmarkNodes.count == 1)
    }

    @Test func deleteBookmarkNodeFiresObservation() async throws {
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)

        // Seed: create a folder, then reload so the model has data.
        _ = await model.createFolder(parentID: nil, name: "Temp")
        await model.bootstrapFromStore()
        #expect(model.bookmarkNodes.count == 1)

        let nodeID = model.bookmarkNodes.first!.id

        let box = Box()
        withObservationTracking {
            _ = model.bookmarkNodes
        } onChange: {
            box.fireCount += 1
        }

        await model.deleteBookmarkNode(id: nodeID)
        await model.bootstrapFromStore()

        #expect(box.fireCount == 1,
                "deleteBookmarkNode → reloadBookmarkNodes must fire the @Observable callback")
        #expect(model.bookmarkNodes.isEmpty)
    }

    @Test func bookmarkNodesObservationIsOneShot() async throws {
        /// `withObservationTracking` installs a one-shot callback — it fires
        /// once, then unregisters. SwiftUI re-registers on each body
        /// re-evaluation, but a raw call does not. This test documents that
        /// contract so a future "optimization" that makes it sticky is caught.
        let store = try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
        let page = try await store.createPage(title: "One-Shot Page")
        let model = WikiStoreModel(store: store)

        let box = Box()
        withObservationTracking {
            _ = model.bookmarkNodes
        } onChange: {
            box.fireCount += 1
        }

        await model.addPageRef(parentID: nil, pageID: page.id)
        await model.addPageRef(parentID: nil, pageID: page.id)
        await model.bootstrapFromStore()

        #expect(box.fireCount == 1,
                "withObservationTracking fires once then unregisters (SwiftUI re-registers per body)")
        #expect(model.bookmarkNodes.count == 2)
    }
}

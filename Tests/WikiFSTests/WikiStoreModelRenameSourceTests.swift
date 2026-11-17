import Foundation
import Testing
@testable import WikiFSCore

/// Regression tests for `WikiStoreModel.renameSource`: the rename must refresh the
/// in-memory `sources` list, or the DB updates but the live UI snaps back to the
/// old name (the "nothing happens when I rename a source" bug — the model only
/// reloaded `summaries`, never `sources`).
@MainActor
struct WikiStoreModelRenameSourceTests {

    private func makeModel() throws -> WikiStoreModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite")))
    }

    @Test func renameSourceRefreshesSourcesList() async throws {
        let model = try makeModel()
        await model.addSource(filename: "old-name.pdf", data: Data("pdf".utf8))
        await model.bootstrapFromStore()
        let id = try #require(model.sources.first?.id)

        await model.renameSource(id: id, to: "Friendly Name")
        await model.bootstrapFromStore()

        let renamed = model.sources.first(where: { $0.id == id })
        #expect(renamed?.displayName == "Friendly Name")
    }
}

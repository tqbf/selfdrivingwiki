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
        return WikiStoreModel(store: try SQLiteWikiStore(
            databaseURL: dir.appendingPathComponent("WikiFS.sqlite")))
    }

    @Test func renameSourceRefreshesSourcesList() throws {
        let model = try makeModel()
        model.addSource(filename: "old-name.pdf", data: Data("pdf".utf8))
        let id = try #require(model.sources.first?.id)

        model.renameSource(id: id, to: "Friendly Name")

        let renamed = model.sources.first(where: { $0.id == id })
        #expect(renamed?.displayName == "Friendly Name")
    }
}

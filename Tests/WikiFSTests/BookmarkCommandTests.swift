import Testing
import Foundation
@testable import WikiCtlCore
@testable import WikiFSCore

/// Tests for `wikictl bookmark` subcommands (#239) — list, create-folder,
/// add-ref, rename, delete, move — against a temp SQLite store.
@Suite struct BookmarkCommandTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-cmd-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> GRDBWikiStore {
        try GRDBWikiStore(databaseURL: tempDatabaseURL())
    }

    private let noEnv: (String) -> String? = { _ in nil }

    // MARK: - list

    @Test func listEmptyBookmarks() throws {
        let store = try tempStore()
        let result = try BookmarkCommand.run(.list(json: false), in: store)
        #expect(result.didCommit == false)
        #expect(result.output.isEmpty)
    }

    @Test func listOutputsTSV() throws {
        let store = try tempStore()
        _ = try store.createBookmarkNode(parentID: nil, position: 0, kind: .folder,
                                          label: "Research", targetID: nil)
        let result = try BookmarkCommand.run(.list(json: false), in: store)
        #expect(result.didCommit == false)
        #expect(result.output.contains("Research"))
        #expect(result.output.contains("folder"))
    }

    @Test func listOutputsJSON() throws {
        let store = try tempStore()
        _ = try store.createBookmarkNode(parentID: nil, position: 0, kind: .folder,
                                          label: "Research", targetID: nil)
        let result = try BookmarkCommand.run(.list(json: true), in: store)
        #expect(result.didCommit == false)
        #expect(result.output.contains("\"label\":\"Research\""))
        #expect(result.output.contains("\"kind\":\"folder\""))
    }

    // MARK: - create-folder

    @Test func createFolderCommitsAndOutputsConfirmation() throws {
        let store = try tempStore()
        let result = try BookmarkCommand.run(
            .createFolder(parentID: nil, name: "Research"), in: store
        )
        #expect(result.didCommit == true)
        #expect(result.output.contains("Research"))
        // Verify it was actually created.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes[0].label == "Research")
    }

    @Test func createNestedFolder() throws {
        let store = try tempStore()
        let parent = try store.createBookmarkNode(parentID: nil, position: 0,
                                                    kind: .folder, label: "Parent", targetID: nil)
        let result = try BookmarkCommand.run(
            .createFolder(parentID: parent.id, name: "Child"), in: store
        )
        #expect(result.didCommit == true)
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 2)
        let child = nodes.first { $0.parentID == parent.id }
        #expect(child?.label == "Child")
    }

    // MARK: - add-ref

    @Test func addPageRefCommits() throws {
        let store = try tempStore()
        let result = try BookmarkCommand.run(
            .addRef(parentID: nil, kind: .pageRef, targetID: PageID(rawValue: "01PAGE")),
            in: store
        )
        #expect(result.didCommit == true)
        #expect(result.output.contains("page"))
        #expect(result.output.contains("01PAGE"))
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes[0].kind == .pageRef)
        #expect(nodes[0].targetID?.rawValue == "01PAGE")
    }

    @Test func addSourceRefCommits() throws {
        let store = try tempStore()
        let result = try BookmarkCommand.run(
            .addRef(parentID: nil, kind: .sourceRef, targetID: PageID(rawValue: "01SRC")),
            in: store
        )
        #expect(result.didCommit == true)
        #expect(result.output.contains("source"))
    }

    @Test func addChatRefCommits() throws {
        let store = try tempStore()
        let result = try BookmarkCommand.run(
            .addRef(parentID: nil, kind: .chatRef, targetID: PageID(rawValue: "01CHAT")),
            in: store
        )
        #expect(result.didCommit == true)
        #expect(result.output.contains("chat"))
    }

    // MARK: - rename

    @Test func renameCommitsAndUpdateLabel() throws {
        let store = try tempStore()
        let node = try store.createBookmarkNode(parentID: nil, position: 0,
                                                 kind: .folder, label: "Old", targetID: nil)
        let result = try BookmarkCommand.run(
            .rename(id: node.id, to: "New"), in: store
        )
        #expect(result.didCommit == true)
        #expect(result.output.contains("New"))
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.first?.label == "New")
    }

    // MARK: - delete

    @Test func deleteCommits() throws {
        let store = try tempStore()
        let node = try store.createBookmarkNode(parentID: nil, position: 0,
                                                 kind: .folder, label: "ToDelete", targetID: nil)
        let result = try BookmarkCommand.run(.delete(id: node.id), in: store)
        #expect(result.didCommit == true)
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.isEmpty)
    }

    // MARK: - move

    @Test func moveCommits() throws {
        let store = try tempStore()
        let node = try store.createBookmarkNode(parentID: nil, position: 0,
                                                 kind: .folder, label: "Movable", targetID: nil)
        let result = try BookmarkCommand.run(
            .move(id: node.id, toParentID: nil, position: 5), in: store
        )
        #expect(result.didCommit == true)
    }

    // MARK: - argument parsing

    @Test func parseListReturnsBookmarkList() throws {
        let inv = try ArgumentParser.parse(["--wiki", "W", "bookmark", "list"], env: noEnv)
        guard case .bookmark(let action) = inv.command,
              case .list(let json) = action else {
            Issue.record("expected .bookmark(.list)"); return
        }
        #expect(json == false)
    }

    @Test func parseCreateFolder() throws {
        let inv = try ArgumentParser.parse([
            "--wiki", "W", "bookmark", "create-folder", "--name", "Research"
        ], env: noEnv)
        guard case .bookmark(let action) = inv.command,
              case .createFolder(let parent, let name) = action else {
            Issue.record("expected .bookmark(.createFolder)"); return
        }
        #expect(parent == nil)
        #expect(name == "Research")
    }

    @Test func parseAddRef() throws {
        let inv = try ArgumentParser.parse([
            "--wiki", "W", "bookmark", "add-ref", "--kind", "page", "--target", "01PAGE"
        ], env: noEnv)
        guard case .bookmark(let action) = inv.command,
              case .addRef(let parent, let kind, let target) = action else {
            Issue.record("expected .bookmark(.addRef)"); return
        }
        #expect(parent == nil)
        #expect(kind == .pageRef)
        #expect(target.rawValue == "01PAGE")
    }

    @Test func parseRename() throws {
        let inv = try ArgumentParser.parse([
            "--wiki", "W", "bookmark", "rename", "--id", "abc", "--to", "NewName"
        ], env: noEnv)
        guard case .bookmark(let action) = inv.command,
              case .rename(let id, let to) = action else {
            Issue.record("expected .bookmark(.rename)"); return
        }
        #expect(id == "abc")
        #expect(to == "NewName")
    }

    @Test func parseDelete() throws {
        let inv = try ArgumentParser.parse([
            "--wiki", "W", "bookmark", "delete", "--id", "abc"
        ], env: noEnv)
        guard case .bookmark(let action) = inv.command,
              case .delete(let id) = action else {
            Issue.record("expected .bookmark(.delete)"); return
        }
        #expect(id == "abc")
    }

    @Test func parseMove() throws {
        let inv = try ArgumentParser.parse([
            "--wiki", "W", "bookmark", "move", "--id", "abc", "--position", "3"
        ], env: noEnv)
        guard case .bookmark(let action) = inv.command,
              case .move(let id, let parent, let pos) = action else {
            Issue.record("expected .bookmark(.move)"); return
        }
        #expect(id == "abc")
        #expect(parent == nil)
        #expect(pos == 3)
    }

    @Test func parseCreateFolderRequiresName() throws {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse(["--wiki", "W", "bookmark", "create-folder"], env: noEnv)
        }
    }

    @Test func parseAddRefRequiresKind() throws {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse([
                "--wiki", "W", "bookmark", "add-ref", "--target", "01PAGE"
            ], env: noEnv)
        }
    }
}

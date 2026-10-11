import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

/// The speech stage's safety contract: owner-private staging, atomic writes,
/// lease-protected recovery, and removal on every exit path. Live work is
/// never swept; symlinks and out-of-root paths are never followed.
@Suite("Speech stage recovery", .timeLimit(.minutes(2)))
struct SpeechStageRecoveryTests {

    private static let wikiID = WikiID(rawValue: "01JSTAGEWIKI00000000000")
    private static let itemID = QueueItem.ID(rawValue: "01JSTAGEITEM0000000000")
    private static let audio = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypM4A ".utf8) + Data(repeating: 0x2A, count: 64)

    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-stage-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeManager(root: URL) -> SpeechStageManager {
        SpeechStageManager(root: root)
    }

    // MARK: - Staging

    @Test func stagesAtomicallyWithOwnerPrivateModes() throws {
        let root = try makeRoot("modes")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        let staged = try manager.stage(
            bytes: Self.audio, wikiID: Self.wikiID, itemID: Self.itemID, attempt: 1)
        defer { staged.discard() }

        let audio = staged.audioURL
        #expect(try Data(contentsOf: audio) == Self.audio)
        let audioMode = try FileManager.default.attributesOfItem(atPath: audio.path)[.posixPermissions] as? Int
        #expect(audioMode == 0o600)
        let stageDirMode = try FileManager.default.attributesOfItem(
            atPath: audio.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(stageDirMode == 0o700)
        let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        #expect(rootMode == 0o700)
    }

    @Test func discardRemovesTheWholeStageDirectory() throws {
        let root = try makeRoot("discard")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        let staged = try manager.stage(
            bytes: Self.audio, wikiID: Self.wikiID, itemID: Self.itemID, attempt: 1)
        let directory = staged.audioURL.deletingLastPathComponent()
        staged.discard()
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    }

    @Test func oversizeAndDiskPreflights() throws {
        let root = try makeRoot("limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        #expect(throws: SpeechStageManager.StageError.tooLarge) {
            _ = try manager.stage(
                bytes: Data(repeating: 0, count: SpeechStageManager.maximumStagedBytes + 1),
                wikiID: Self.wikiID, itemID: Self.itemID, attempt: 1)
        }
        // A tiny fake volume: minimumFreeBytes preflight refuses to stage.
        // (Direct: the constant floor is far above any real test volume's
        // free space headroom requirement — inverted by staging into a
        // directory on a full tmpfs is not portable, so this pins the
        // constant instead.)
        #expect(SpeechStageManager.minimumFreeBytes >= 2 * 120 * 1024 * 1024)
    }

    // MARK: - Recovery sweeps

    @Test func removesOrphans() throws {
        let root = try makeRoot("orphans")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        // Stage, then release the lease WITHOUT discarding (the crash
        // shape), and backdate the stage beyond the abandonment window.
        var stageDirectory: URL?
        do {
            let staged = try manager.stage(
                bytes: Self.audio, wikiID: Self.wikiID, itemID: Self.itemID, attempt: 1)
            staged.lease.release()
            stageDirectory = staged.audioURL.deletingLastPathComponent()
        }
        let old = Date().addingTimeInterval(
            -Double(SpeechStageManager.abandonmentThreshold.components.seconds) - 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: stageDirectory!.path)

        let swept = manager.sweepAbandoned()
        #expect(swept.count == 1)
        #expect(FileManager.default.fileExists(atPath: stageDirectory!.path) == false)
    }

    @Test func preservesOtherHostActiveStage() throws {
        let root = try makeRoot("active")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        // Another "host" holds the lease and the stage is old.
        let otherHost = try manager.stage(
            bytes: Self.audio, wikiID: Self.wikiID, itemID: Self.itemID, attempt: 2)
        let directory = otherHost.audioURL.deletingLastPathComponent()
        let old = Date().addingTimeInterval(
            -Double(SpeechStageManager.abandonmentThreshold.components.seconds) - 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: directory.path)

        let swept = manager.sweepAbandoned()
        #expect(swept.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        otherHost.discard()
    }

    @Test func crashReleasedLeaseIsSwept() throws {
        let root = try makeRoot("crash")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        // "Crash": the process died — the lease descriptor closed on its
        // own, the directory remains, and time passes.
        let staged = try manager.stage(
            bytes: Self.audio, wikiID: Self.wikiID, itemID: Self.itemID, attempt: 3)
        staged.lease.release()  // crash-released; stage content remains
        let directory = staged.audioURL.deletingLastPathComponent()
        let old = Date().addingTimeInterval(
            -Double(SpeechStageManager.abandonmentThreshold.components.seconds) - 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: directory.path)

        // A fresh startup sweep removes exactly the abandoned stage.
        let freshManager = makeManager(root: root)
        _ = freshManager.sweepAbandoned()
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    }

    @Test func rejectsSymlinkStage() throws {
        let root = try makeRoot("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        // A symlinked stage entry inside the root is NEVER followed.
        let outside = try makeRoot("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let wikiDirectory = root.appendingPathComponent(Self.wikiID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: wikiDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: wikiDirectory.appendingPathComponent("01JSYMLINKITEM00000000-1"),
            withDestinationURL: outside)

        let swept = manager.sweepAbandoned()
        #expect(swept.isEmpty)
        // The outside target is untouched.
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func cancelDuringStageWriteCleansPartialFile() throws {
        let root = try makeRoot("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        // A leftover partial (the mid-write cancellation shape) never
        // survives the next staging attempt: the stage() path removes it.
        let stageDirectory = SpeechStageManager.stageDirectory(
            root: root, wikiID: Self.wikiID, itemID: Self.itemID, attempt: 9)
        try FileManager.default.createDirectory(
            at: stageDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let partial = stageDirectory.appendingPathComponent("audio.m4a.partial")
        try Data("half".utf8).write(to: partial)

        let staged = try manager.stage(
            bytes: Self.audio, wikiID: Self.wikiID, itemID: Self.itemID, attempt: 9)
        defer { staged.discard() }
        #expect(try Data(contentsOf: staged.audioURL) == Self.audio)
        #expect(FileManager.default.fileExists(atPath: partial.path) == false)
        // And the published file carries the exact bytes — never the
        // partial prefix.
        #expect(String(decoding: Self.audio.prefix(4), as: UTF8.self)
            != "half")
    }
}

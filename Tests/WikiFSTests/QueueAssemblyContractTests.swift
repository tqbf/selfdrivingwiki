#if canImport(WikiFSEngine)
import Foundation
import Testing

@Suite("Queue assembly source contracts", .timeLimit(.minutes(1)))
struct QueueAssemblyContractTests {
    @Test("app and daemon assembly contain no mutable emit boxes or installation tasks")
    func removedEmitBoxesAndAssignmentsAreAbsent() throws {
        let root = repositoryRoot()
        let paths = [
            "Sources/WikiFS/Window/WikiFSApp.swift",
            "Sources/WikiFS/Queue/QueueActivityTracker.swift",
            "Sources/wikid/WikiDaemon.swift",
        ]
        let source = try paths.map { path in
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }.joined(separator: "\n")
        let forbidden = [
            "ProgressEmitBox",
            "TranscriptEmitBox",
            "UsageEmitBox",
            "LiveUsageEmitBox",
            "LogPathsEmitBox",
            "PendingPermissionEmitBox",
            "DaemonEmitBox",
            ".emit = await",
            ".install(await",
        ]

        for pattern in forbidden {
            #expect(!source.contains(pattern), "Found obsolete queue callback cycle: \(pattern)")
        }
    }

    @Test("every daemon queue selector routes through the queue host")
    func daemonQueueSelectorsUseHostAdmission() throws {
        let root = repositoryRoot()
        let completeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/wikid/main.swift"),
            encoding: .utf8)
        let productionSource = try #require(
            completeSource.components(separatedBy: "    #else\n    // Linux stubs").first)
        let admittedSelectors = [
            "queueSnapshot", "enqueueItem", "cancelItem", "cancelAllInFlight",
            "retryItem", "pauseQueue", "resumeQueue", "haltQueue", "reorderItem",
            "hasActiveWork", "waitForCompletion", "loadTranscript",
            "loadAllActivitySnapshots",
        ]

        for selector in admittedSelectors {
            let body = try #require(functionSource(named: selector, in: productionSource))
            #expect(
                body.contains("queueReply(") || body.contains("queueControlReply("),
                "Queue selector bypasses DaemonQueueHost admission: \(selector)")
        }
        let controlHelper = try #require(
            functionSource(named: "queueControlReply", in: productionSource))
        #expect(controlHelper.contains("performQueueOperation"))
        let status = try #require(
            functionSource(named: "queueOwnershipStatus", in: productionSource))
        #expect(status.contains("queueHostStatus"))
        let relinquish = try #require(
            functionSource(named: "relinquishQueue", in: productionSource))
        #expect(relinquish.contains("daemon.relinquishQueue"))
    }

    @Test("both construction roots use one ready output channel")
    func constructionRootsInjectReadyChannel() throws {
        let root = repositoryRoot()
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Window/WikiFSApp.swift"),
            encoding: .utf8)
        let daemon = try String(
            contentsOf: root.appendingPathComponent("Sources/wikid/WikiDaemon.swift"),
            encoding: .utf8)

        #expect(app.contains("QueueRuntimeAssembly("))
        #expect(!app.contains("QueueWorkerOutputChannel(store:"))
        #expect(daemon.contains("let outputChannel = QueueWorkerOutputChannel(store: queueStore)"))
        #expect(daemon.contains("outputChannel: outputChannel"))
    }
}

private func functionSource(named name: String, in source: String) -> String? {
    let markers = ["    func \(name)(", "    private func \(name)("]
    guard let start = markers.compactMap({ source.range(of: $0)?.lowerBound }).min() else {
        return nil
    }
    let suffix = source[start...]
    let nextPublic = suffix.dropFirst().range(of: "\n    func ")?.lowerBound
    let nextPrivate = suffix.dropFirst().range(of: "\n    private func ")?.lowerBound
    let end = [nextPublic, nextPrivate].compactMap { $0 }.min() ?? source.endIndex
    return String(source[start..<end])
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
#endif

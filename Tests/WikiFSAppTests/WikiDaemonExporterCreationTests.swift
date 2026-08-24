#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import wikid

@Suite("Wiki daemon create exporter", .serialized, .timeLimit(.minutes(1)))
struct WikiDaemonExporterCreationTests {
    @Test("create replies exactly once after profile publication")
    func createRepliesExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-exporter-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let daemon = try await WikiDaemon.profileBackedForTesting(containerDirectory: directory)
        let exporter = WikiDaemonExporter(daemon: daemon)

        let replies = AsyncStream<Data?>.makeStream()
        let replyCount = LockedReplyCount()
        exporter.createWiki(name: "Exporter") { data in
            replyCount.increment()
            replies.continuation.yield(data)
            replies.continuation.finish()
        }
        let reply = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                var iterator = replies.stream.makeAsyncIterator()
                return await iterator.next() ?? nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ExporterReplyTimeout()
            }
            let value = try await group.next() ?? nil
            group.cancelAll()
            return value
        }
        #expect(reply != nil)
        await daemon.shutdown()
        #expect(replyCount.value == 1)
    }
}

private struct ExporterReplyTimeout: Error {}

private final class LockedReplyCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
#endif

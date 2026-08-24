#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

@Suite("Daemon prepared store resolution", .serialized, .timeLimit(.minutes(1)))
struct DaemonStoreResolverTests {
    private func makeTempDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-store-resolver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("synchronous resolver rejects an unprepared wiki")
    func synchronousPreparedStoreResolverThrowsBeforePreparation() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let daemon = WikiDaemon(containerDirectory: directory)
        let wikiID = WikiID(rawValue: "not-prepared")

        #expect(throws: DaemonStoreResolutionError.notPrepared(wikiID)) {
            try daemon.resolvePreparedStore(wikiID: wikiID)
        }
    }

}
#endif

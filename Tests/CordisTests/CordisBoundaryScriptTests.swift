import Foundation
import Testing

@Suite("Cordis boundary script", .serialized, .timeLimit(.minutes(1)))
struct CordisBoundaryScriptTests {
    @Test("current source tree satisfies the boundary baseline")
    func currentTreeSatisfiesBoundaryBaseline() async throws {
        let root = repositoryRoot()
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = root.appendingPathComponent("scripts/check-cordis-boundaries")
        let standardError = Pipe()
        process.standardError = standardError

        let terminations = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }
        try process.run()
        for await _ in terminations { break }

        let errorData = try standardError.fileHandleForReading.readToEnd() ?? Data()
        let errorOutput = String(decoding: errorData, as: UTF8.self)
        #expect(process.terminationStatus == 0, "Boundary check failed: \(errorOutput)")
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

#if os(macOS)
import Foundation
import Testing
import WikiCtlCore
import WikiDaemonContract
@testable import wikid

/// The eval daemon substrate the lint-eval host boots
/// (``LintEvalDaemonSubstrate``): registry + dispatcher + socket server +
/// registration broker + scoped-run lease manager registered in ONE process,
/// serving the dedicated eval container's `wikid-search.sock`.
///
/// The 2026-10-25 gate run starved this socket: the substrate booted and
/// served binds, but the host's blocked main thread kept every handler from
/// settling. This suite pins the endpoint at the seam the live-gate clients
/// bind to (a real `hello` round trip through the real socket path) so a
/// substrate wiring regression fails deterministically here.
///
/// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`; the
/// round trip rides the client's own 30 s deadline.
@Suite("LintEvalDaemonSubstrate", .serialized, .timeLimit(.minutes(2)))
struct LintEvalDaemonSubstrateTests {

    @Test func substrateServesCapabilitiesThroughTheRealSocketPath() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lintgate-sub-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let substrate = try LintEvalDaemonSubstrate(containerDirectory: container)
        defer { substrate.stop() }

        // The endpoint the live-gate clients resolve: the eval container's
        // ordinary socket file name.
        #expect(substrate.socketPath.hasSuffix(SearchSocketWire.socketFileName))

        // One real round trip through the real socket: the uncredentialed
        // capabilities handshake, the cheapest request that exercises the
        // full path (frame in -> dispatcher -> frame out).
        let client = try DaemonDomainSocketClient(containerDirectory: container)
        let hello = try await client.hello()
        #expect(hello.protocolVersion == DaemonDomainVersion.current)
        #expect(hello.families.contains("hello"))
        #expect(hello.families.contains("wiki"))
    }
}
#endif

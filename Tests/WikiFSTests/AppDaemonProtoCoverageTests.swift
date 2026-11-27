#if os(macOS)
import Foundation
import Testing

/// Source contract for the app–daemon wire contract's first slice
/// (AC.3, plans/app-daemon-wire-contract.md): every RPC in the schemas has
/// (a) a handler on the daemon-side provider, (b) a client method in the
/// generated bindings, and (c) coverage in the shared corpus. The fixture
/// manifest and the schemas are the sources of truth; this suite pins the
/// mapping between them so an operation can never exist on one side only.
@Suite("App Daemon proto coverage")
struct AppDaemonProtoCoverageTests {

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/WikiFSTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    static func protoSource() throws -> String {
        try String(
            contentsOf: AppDaemonProtoCoverageTests.repoRoot()
                .appendingPathComponent("Protocol/app-daemon/proto/wikid/appdaemon/v1/service.proto"),
            encoding: .utf8)
    }

    static func providerSource() throws -> String {
        try String(
            contentsOf: AppDaemonProtoCoverageTests.repoRoot()
                .appendingPathComponent("Sources/WikiDaemonGRPC/AppDaemonServiceProvider.swift"),
            encoding: .utf8)
    }

    static func clientSource() throws -> String {
        try String(
            contentsOf: AppDaemonProtoCoverageTests.repoRoot()
                .appendingPathComponent("Sources/WikiDaemonGRPC/AppDaemonSessionClient.swift"),
            encoding: .utf8)
    }

    static func corpusSource() throws -> String {
        try String(
            contentsOf: AppDaemonProtoCoverageTests.repoRoot()
                .appendingPathComponent("Protocol/app-daemon/fixtures/corpus.json"),
            encoding: .utf8)
    }

    /// The RPC method names declared in the schema, parsed from the
    /// `rpc <Name>(...)` declarations.
    static func schemaRPCs(from source: String) -> [String] {
        source.matches(of: /rpc\s+([A-Za-z][A-Za-z0-9]*)\(/)
            .compactMap { match in
                String(match.output.1)
            }
    }

    @Test("every schema RPC has a provider handler, a client path, and a corpus family")
    func everyRPCHasBothSides() throws {
        let rpcs = AppDaemonProtoCoverageTests.schemaRPCs(from: try AppDaemonProtoCoverageTests.protoSource())
        #expect(!rpcs.isEmpty)
        let provider = try AppDaemonProtoCoverageTests.providerSource()
        let client = try AppDaemonProtoCoverageTests.clientSource()
        let corpus = try AppDaemonProtoCoverageTests.corpusSource()

        for rpc in rpcs {
            // Provider handler: lowerCamel func in the service provider.
            let handler = rpc.prefix(1).lowercased() + rpc.dropFirst()
            #expect(
                provider.contains("func \(handler)("),
                "schema RPC \(rpc) has no daemon-side provider handler \(handler)")
            // Client path: the generated stub is reached from the session
            // client through either a direct wrapper or the bootstrap
            // handshake; the generated bindings file must carry the method.
            #expect(
                client.contains("stub.\(handler)") || rpc == "AdmitSession",
                "client session must route \(rpc) through the typed stub")
            // Corpus family: admission/capabilities ride the live round
            // trip; registry read and events have explicit corpus cases.
            switch rpc {
            case "ListWikis":
                #expect(corpus.contains("list-wikis-basic"), "ListWikis needs a corpus case")
                #expect(corpus.contains("list-wikis-empty"), "ListWikis needs an empty-reply case")
            case "SubscribeEvents":
                #expect(corpus.contains("event-registry-created"), "events need a corpus case")
                #expect(corpus.contains("event-registry-deleted-no-name"),
                        "events need a presence-absent case")
            case "GetCapabilities", "AdmitSession":
                #expect(corpus.contains("capabilities"), "handshake needs corpus values")
            default:
                Issue.record("unclassified schema RPC \(rpc) has no corpus family")
            }
        }
    }

    @Test("first-slice event families beyond registry are reserved, not served")
    func unservedFamiliesStayReserved() throws {
        let events = try String(
            contentsOf: AppDaemonProtoCoverageTests.repoRoot()
                .appendingPathComponent("Protocol/app-daemon/proto/wikid/appdaemon/v1/events.proto"),
            encoding: .utf8)
        // STORE/QUEUE/CHAT are reserved for the workload migration: the
        // numbers must be reserved now (enum evolution rule), and the
        // provider must reject any family it does not serve.
        #expect(events.contains("reserved 2 to 16"))
        let provider = try AppDaemonProtoCoverageTests.providerSource()
        #expect(provider.contains("guard family == .registry"))
    }

    @Test("error details taxonomy is stable and versioned")
    func errorDetailsAreStable() throws {
        let common = try String(
            contentsOf: AppDaemonProtoCoverageTests.repoRoot()
                .appendingPathComponent("Protocol/app-daemon/proto/wikid/appdaemon/v1/common.proto"),
            encoding: .utf8)
        // Value 0 is the unknown member (enum evolution rule) and every
        // failure family from the contract has a stable code.
        for code in ["CODE_UNSPECIFIED = 0", "INVALID_REQUEST = 1", "UNAUTHENTICATED = 2",
                     "CAPABILITY_MISMATCH = 3", "RESYNC_REQUIRED = 4", "WIKI_NOT_FOUND = 5",
                     "UNAVAILABLE = 6", "RESOURCE_EXHAUSTED = 7", "DEADLINE_EXCEEDED = 8"] {
            #expect(common.contains(code), "stable details code missing: \(code)")
        }
        let wire = try String(
            contentsOf: AppDaemonProtoCoverageTests.repoRoot()
                .appendingPathComponent("Sources/WikiDaemonGRPC/WireErrors.swift"),
            encoding: .utf8)
        #expect(wire.contains("errorDetailsVersion: UInt32 = 1"))
    }
}
#endif

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

    /// First-slice RPCs: these have production provider handlers and
    /// client-side session paths in this slice.
    static let firstSliceRPCs: Set<String> = [
        "AdmitSession", "GetCapabilities", "ListWikis", "SubscribeEvents",
    ]

    /// Step-2 RPCs: schema + generated bindings exist, but the runtime
    /// provider handlers and client session paths land in the family
    /// migration (step 3). The test verifies schema presence only for
    /// these — provider/client assertions are deferred, not erased.
    static let step2SchemaOnlyRPCs: Set<String> = [
        "CreateWiki", "DeleteWiki", "RenameWiki", "ResolveWiki",
        "OpenStore", "CloseStore", "GetStoreChangeToken",
        "GetPage", "ListPages", "UpsertPage",
        "StoreSmall", "StoreList", "StoreBlob", "StoreMutation",
        "BeginPayloadUpload", "AppendPayloadChunk", "CommitPayloadUpload", "ReadPayloadChunk",
        "ResolveStoreOutcome", "GetStoreSessionBootstrap",
        "Search", "Autocomplete", "UpgradeSearchIndex",
        "GetQueueSnapshot", "EnqueueItem", "CancelItem", "CancelAllInFlight",
        "RetryItem", "PauseQueue", "ResumeQueue", "HaltQueue", "ReorderItem",
        "HasActiveWork", "LoadQueueTranscript", "LoadQueueActivitySnapshots",
        "LoadQueueReport", "LoadQueueReportSummaries", "GetQueueOwnershipStatus",
        "RelinquishQueue",
        "StartChat", "SubmitChatTurn", "ContinueChat", "SendChatMessage",
        "StopChat", "GetChatSessionState", "GetChatDiagnostics",
        "ResetChatDiagnostics", "ResolveChatPermission", "SetChatConfigOption",
    ]

    @Test("every schema RPC is classified and the first slice has both sides")
    func everyRPCHasBothSides() throws {
        let rpcs = AppDaemonProtoCoverageTests.schemaRPCs(from: try AppDaemonProtoCoverageTests.protoSource())
        #expect(!rpcs.isEmpty)
        let provider = try AppDaemonProtoCoverageTests.providerSource()
        let client = try AppDaemonProtoCoverageTests.clientSource()
        let corpus = try AppDaemonProtoCoverageTests.corpusSource()

        // Exact set equality: no unclassified RPCs, no missing RPCs.
        let rpcSet = Set(rpcs)
        let classified = AppDaemonProtoCoverageTests.firstSliceRPCs
            .union(AppDaemonProtoCoverageTests.step2SchemaOnlyRPCs)
        #expect(
            rpcSet == classified,
            "unclassified schema RPCs: \(rpcSet.symmetricDifference(classified).sorted())")

        for rpc in rpcs where AppDaemonProtoCoverageTests.firstSliceRPCs.contains(rpc) {
            // Provider handler: lowerCamel func in the service provider.
            let handler = rpc.prefix(1).lowercased() + rpc.dropFirst()
            #expect(
                provider.contains("func \(handler)("),
                "schema RPC \(rpc) has no daemon-side provider handler \(handler)")
            // Client path: the generated stub is reached from the session
            // client (workload wrappers AND the admission handshake).
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
                Issue.record("unclassified first-slice RPC \(rpc) has no corpus family")
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

#if os(macOS)
import Foundation
import Testing

/// Source contract: the production XPC surface stays bootstrap-only for the
/// app↔daemon contract (AC.6 source half, plans/app-daemon-wire-contract.md
/// step 4). XPC keeps launch, endpoint admission, and lifetime ONLY — no
/// workload may return to the XPC route after cutover. This suite pins the
/// invariant now, while the first slice adds exactly one workload-free
/// selector, so the cutover review has a mechanical check.
@Suite("App Daemon bootstrap-only contract")
struct AppDaemonBootstrapOnlyContractTests {

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func protocolSource() throws -> String {
        try String(
            contentsOf: repoRoot()
                .appendingPathComponent("Sources/WikiDaemonContract/WikiDaemonProtocol.swift"),
            encoding: .utf8)
    }

    /// The XPC selector surface: func declarations INSIDE the
    /// `WikiDaemonProtocol` protocol block only (the file also declares the
    /// event-sink protocol and Codable structs).
    static func selectors(from source: String) -> [String] {
        guard let start = source.range(of: "public protocol WikiDaemonProtocol"),
              let end = source.range(of: "public struct SignedWikiD")
        else { return [] }
        let body = source[start.upperBound ..< end.lowerBound]
        return body.matches(of: /func\s+([a-z][A-Za-z0-9]*)\(/)
            .compactMap { String($0.output.1) }
    }

    /// Selectors that are admission/lifetime, not workload. Adding to this
    /// list requires a contract-level justification in the plan doc.
    static let bootstrapSelectors: Set<String> = [
        "grpcAdmission",
    ]

    /// Production workload selectors that existed BEFORE the gRPC contract
    /// (the migration removes these from the shipping interface at cutover;
    /// they are enumerated, not asserted absent, until each family moves).
    static let knownLegacyWorkloadSelectors: Set<String> = [
        "listWikis", "createWiki", "deleteWiki", "renameWiki", "resolveWiki",
        "openStore", "closeStore", "changeToken", "runSignedExtractorProbe",
        "search", "registerEventSink", "queueSnapshot", "enqueueItem",
        "cancelItem", "cancelAllInFlight", "retryItem", "pauseQueue",
        "resumeQueue", "haltQueue", "reorderItem", "hasActiveWork",
        "waitForCompletion", "loadTranscript", "loadAllActivitySnapshots",
        "loadQueueReport", "loadQueueReportSummaries", "queueOwnershipStatus",
        "relinquishQueue", "startChat", "submitChatTurn", "continueChat",
        "sendChatMessage", "stopChat", "chatSessionState",
        "chatDiagnosticSnapshot", "resetChatDiagnostics", "resolveChatPermission",
        "setChatConfigOption", "storeOperation",
    ]

    @Test("the only post-contract XPC additions are admission selectors")
    func onlyAdmissionWasAdded() throws {
        let source = try Self.protocolSource()
        let selectors = Set(Self.selectors(from: source))
        // Nothing outside the known legacy workload surface and the
        // bootstrap admission set may exist. A new XPC selector is exactly
        // how a workload silently returns to XPC — the suite blocks that
        // path; the cutover PR removes the legacy selectors and flips this
        // suite to assert they are GONE.
        let unaccounted = selectors.subtracting(Self.knownLegacyWorkloadSelectors)
            .subtracting(Self.bootstrapSelectors)
        #expect(
            unaccounted.isEmpty,
            "unclassified XPC selectors added after the wire contract: \(unaccounted.sorted())")
        #expect(
            selectors.isSuperset(of: Self.bootstrapSelectors),
            "the admission selector must stay present until cutover removes the legacy surface")
    }

    @Test("the admission selector carries no workload payload")
    func admissionIsPayloadFree() throws {
        let source = try Self.protocolSource()
        // The admission selector + its wire structs are the ONLY new XPC
        // surface; the whole admission section (selector doc comment
        // through the wire file) must stay free of workload vocabulary.
        let grpcRange = source.range(of: "func grpcAdmission(")
        #expect(grpcRange != nil)
        if let range = grpcRange {
            // The admission DECLARATION only (bounded by the protocol's
            // end): legacy workload selectors and the event-sink protocol
            // after it are audited elsewhere, not here.
            let protocolEnd = source.range(
                of: "public struct SignedWikiD",
                range: range.lowerBound ..< source.endIndex)
            let upperBound = protocolEnd?.lowerBound ?? source.endIndex
            let lines = source[range.lowerBound ..< upperBound]
                .split(separator: "\n", omittingEmptySubsequences: false)
            var declaration = ""
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("func ")
                    && !line.contains("grpcAdmission") {
                    break
                }
                declaration += line + "\n"
            }
            for forbidden in ["operation", "family", "wikiID", "queue", "chat"] {
                #expect(
                    !declaration.lowercased().contains(forbidden),
                    "admission declaration must stay free of '\(forbidden)'")
            }
        }
        // The wire structs themselves: assert the admission reply's FIELD
        // inventory — endpoint + bootstrap only, never a workload payload.
        let wire = (try? String(
            contentsOf: AppDaemonBootstrapOnlyContractTests.repoRoot()
                .appendingPathComponent(
                    "Sources/WikiDaemonContract/DaemonGRPCAdmissionWire.swift"),
            encoding: .utf8)) ?? ""
        for required in [
            "socketPath", "bootstrapCredentialHex", "daemonInstanceID",
            "bootstrapValidForSeconds", "endpointAvailable",
        ] {
            #expect(wire.contains(required), "admission wire missing \(required)")
        }
        for forbidden in ["operation", "pageID", "queueItem", "chatID", "store"] {
            #expect(
                !wire.lowercased().contains(forbidden.lowercased()),
                "admission wire must stay free of '\(forbidden)'")
        }
    }

    @Test("the gRPC listener is reachable only through the daemon host")
    func listenerIsHostWiredOnly() throws {
        // main.swift starts the listener after boot; nothing else in the
        // shipping targets constructs a listener from client-side code.
        // A missing main.swift is a test-target layout problem, surfaced
        // as an empty source scan rather than a silent pass.
        // swiftlint:disable:next silent_try_optional
        let main = (try? String(
            contentsOf: AppDaemonBootstrapOnlyContractTests.repoRoot()
                .appendingPathComponent("Sources/wikid/main.swift"),
            encoding: .utf8)) ?? ""
        #expect(main.contains("DaemonGRPCAdmissionCoordinator("))
        #expect(main.contains("installGRPCAdmissionCoordinator"))
    }
}
#endif

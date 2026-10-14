import Testing
import Foundation
import WikiFSTestSupport
import WikiFSCore
@testable import WikiFSEngine

/// The candidate probe's failure table against a deterministic local ACP
/// fixture (a POSIX-shell JSON-RPC subprocess). These tests spawn REAL
/// processes through the REAL sandboxed launch plan, so the suite follows
/// the pool-starvation rules (AGENTS.md #1051): non-blocking termination,
/// timeout-raced probes, `.serialized` + `.timeLimit`.
///
/// The probe is initialize-only BY CONSTRUCTION. Two guards pin that:
/// 1. The behavioral modes — a fixture that answers `initialize` and
///    hard-exits on any other request keeps a compliant probe succeeding.
/// 2. `probeNeverReferencesAuthOrSessionTraffic` scans the probe's source
///    so an `authenticate`/`newSession`/model-discovery call can never be
///    reintroduced silently.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ACPAdapterCandidateProbeTests {

    /// The fixture modes and what the probe must conclude.
    private static let fixtureScript = """
    #!/bin/sh
    # Deterministic ACP candidate fixture. Usage: fixture.sh --mode <mode>
    # Modes:
    #   success     answer initialize with the codex identity + in-range version
    #   mismatch    answer initialize with a WRONG identity
    #   badversion  answer initialize with a version outside the contract range
    #   badprotocol answer initialize with protocolVersion 2
    #   noinfo      answer initialize with NO agentInfo
    #   no-response read stdin, answer nothing (probe must time out)
    #   malformed   answer initialize with a non-JSON line
    #   early-exit  exit 3 immediately
    MODE="$2"
    case "$MODE" in
      early-exit) exit 3 ;;
    esac
    NAME="@agentclientprotocol/codex-acp"
    VERSION="2.9.0"
    PROTOCOL=1
    case "$MODE" in
      mismatch) NAME="not-the-contract-identity" ;;
      badversion) VERSION="9.9.9" ;;
      badprotocol) PROTOCOL=2 ;;
    esac
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          case "$MODE" in
            no-response) ;;
            malformed) printf 'this is not json\\n' ;;
            *)
              ID=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              if [ "$MODE" = "noinfo" ]; then
                BODY="{\\"protocolVersion\\":$PROTOCOL,\\"agentCapabilities\\":{},\\"authMethods\\":[]}"
              else
                BODY="{\\"protocolVersion\\":$PROTOCOL,\\"agentCapabilities\\":{},\\"agentInfo\\":{\\"name\\":\\"$NAME\\",\\"title\\":\\"Fixture\\",\\"version\\":\\"$VERSION\\"},\\"authMethods\\":[]}"
              fi
              printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$ID" "$BODY"
              ;;
          esac
          ;;
        *'"method"'*)
          # The probe must NEVER send anything but initialize. Any other
          # request: exit loudly without responding so an awaiting probe call
          # fails its transport instead of hanging.
          exit 42
          ;;
      esac
    done
    """

    // MARK: - Harness

    /// A test-owned root: the fixture script, the probe's scratch parent,
    /// all under one unique directory.
    private func makeSandbox(
        mode: String
    ) throws -> (root: URL, fixturePath: URL, provider: AgentProvider, command: [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-candidate-probe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixturePath = root.appendingPathComponent("fixture.sh")
        try Self.fixtureScript.write(to: fixturePath, atomically: true, encoding: .utf8)
        let command = ["/bin/sh", fixturePath.path, "--mode", mode]
        let provider = AgentProvider(
            id: ProviderID(rawValue: "codex-acp"),
            label: "Fixture Codex",
            command: command,
            env: [:],
            enabled: true,
            isDefault: false)
        return (root, fixturePath, provider, command)
    }

    private func makeProbe(sandbox: (root: URL, fixturePath: URL, provider: AgentProvider, command: [String])) -> ACPAdapterCandidateProbe {
        ACPAdapterCandidateProbe(
            provider: sandbox.provider,
            resolvedCommand: sandbox.command,
            apiKey: nil,
            scratchParent: sandbox.root)
    }

    private func cleanup(_ root: URL) {
        // Best-effort sweep; failures are logged, never thrown (teardown).
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            DebugLog.agent("ACPAdapterCandidateProbeTests: cleanup failed — \(error.localizedDescription)")
        }
    }

    // MARK: - The failure table

    @Test func successfulCandidateReportsContractIdentityAndVersion() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        let sandbox = try makeSandbox(mode: "success")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        let report = try await probe.runHandshake(timeout: .seconds(30))
        #expect(report.protocolVersion == 1)
        #expect(report.reportedIdentity == CodexThinkingCapabilityAdapter.identity)
        #expect(report.reportedVersion == ACPAgentVersion(rawValue: "2.9.0"))
        // The report passes the contract verification — the adopt path.
        let contract = try #require(ACPAdapterCompatibility.contract(forPackage: "@agentclientprotocol/codex-acp"))
        #expect(ACPAdapterProbeVerification.verify(report, contract: contract) == .accepted)
    }

    @Test func identityMismatchCandidateIsRejected() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        let sandbox = try makeSandbox(mode: "mismatch")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        let report = try await probe.runHandshake(timeout: .seconds(30))
        let contract = try #require(ACPAdapterCompatibility.contract(forPackage: "@agentclientprotocol/codex-acp"))
        guard case .rejected(.identityMismatch) = ACPAdapterProbeVerification.verify(report, contract: contract) else {
            Issue.record("expected identityMismatch, got \(report)")
            return
        }
    }

    @Test func outOfRangeCandidateVersionIsRejected() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        // Defense in depth: the probe reads what the CANDIDATE reports, not
        // what the registry claimed.
        let sandbox = try makeSandbox(mode: "badversion")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        let report = try await probe.runHandshake(timeout: .seconds(30))
        let contract = try #require(ACPAdapterCompatibility.contract(forPackage: "@agentclientprotocol/codex-acp"))
        guard case .rejected(.versionOutsideContract) = ACPAdapterProbeVerification.verify(report, contract: contract) else {
            Issue.record("expected versionOutsideContract, got \(report)")
            return
        }
    }

    @Test func wrongProtocolCandidateIsRejected() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        let sandbox = try makeSandbox(mode: "badprotocol")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        let report = try await probe.runHandshake(timeout: .seconds(30))
        let contract = try #require(ACPAdapterCompatibility.contract(forPackage: "@agentclientprotocol/codex-acp"))
        guard case .rejected(.unsupportedProtocol(let reported)) = ACPAdapterProbeVerification.verify(report, contract: contract) else {
            Issue.record("expected unsupportedProtocol, got \(report)")
            return
        }
        #expect(reported == 2)
    }

    @Test func missingAgentInfoCandidateIsRejectedIdentityMissing() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        let sandbox = try makeSandbox(mode: "noinfo")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        let report = try await probe.runHandshake(timeout: .seconds(30))
        let contract = try #require(ACPAdapterCompatibility.contract(forPackage: "@agentclientprotocol/codex-acp"))
        #expect(ACPAdapterProbeVerification.verify(report, contract: contract) == .rejected(.identityMissing))
    }

    @Test func silentCandidateTimesOutAndThrows() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        let sandbox = try makeSandbox(mode: "no-response")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        await #expect(throws: ACPProviderModelProbeError.self) {
            try await probe.runHandshake(timeout: .seconds(3))
        }
    }

    @Test func malformedResponseThrowsLaunchFailed() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        let sandbox = try makeSandbox(mode: "malformed")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        // The SDK's own initialize timeout is long and ignores cooperative
        // cancellation; the probe's outer bound is what stops this test, so
        // keep it tight. The assertion is only "a focused probe error".
        await #expect(throws: ACPProviderModelProbeError.self) {
            try await probe.runHandshake(timeout: .seconds(5))
        }
    }

    @Test func earlyExitCandidateThrowsLaunchFailed() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        let sandbox = try makeSandbox(mode: "early-exit")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        await #expect(throws: ACPProviderModelProbeError.self) {
            try await probe.runHandshake(timeout: .seconds(30))
        }
    }

    @Test func cancelledProbeThrowsAndDoesNotHang() async throws {
        let subprocessGate = try await SubprocessGate.shared.acquire() // #1412 family
        defer { subprocessGate.release() }
        let sandbox = try makeSandbox(mode: "no-response")
        defer { cleanup(sandbox.root) }
        let probe = makeProbe(sandbox: sandbox)
        let task = Task {
            try await probe.runHandshake(timeout: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        // The cancellation must surface promptly (the hard bound guarantees
        // it even though the SDK ignores cooperative cancellation) — never a
        // hang.
        do {
            _ = try await task.value
            Issue.record("expected the cancelled probe to throw")
        } catch is CancellationError {
            // acceptable
        } catch let error as ACPProviderModelProbeError {
            #expect(error == .timedOut)
        }
    }

    // MARK: - Structural guard

    /// The probe is initialize-only. Scan its source: no authenticate, no
    /// session traffic, no model discovery. A regression reintroducing any
    /// of them fails this test before it ships.
    @Test func probeNeverReferencesAuthOrSessionTraffic() throws {
        let probeSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WikiFSEngine/ACPAdapterCandidateProbe.swift")
        let source = try String(contentsOf: probeSourceURL, encoding: .utf8)
        for forbidden in [".authenticate(", "newSession(", "discoverObservation(", "session/set_model", "setConfigOption"] {
            #expect(
                !source.contains(forbidden),
                "ACPAdapterCandidateProbe must stay initialize-only: found \(forbidden)")
        }
    }
}

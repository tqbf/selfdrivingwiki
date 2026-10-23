#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine
@testable import WikiFSEngine
@testable import wikid

// Phase 3 unit contracts for the managed-run integration
// (plans/agent-sandbox-scoping.md §5/§7): the daemon-side lease manager over
// the real broker, and the credential delivery into every adapter spawn
// shape. The LIVE enforcement matrix (real sandbox-exec children + the real
// CLI) lives in `AgentSandboxProcessTests`.

@Suite("Scoped run lease manager", .serialized, .timeLimit(.minutes(5)))
struct DaemonScopedRunLeaseManagerTests {

    /// A fixture container short enough for every endpoint path to fit
    /// `sockaddr_un` (the tempRoot shape from the sandbox suites).
    private func makeFixture() throws -> (
        container: URL, broker: DaemonRunRegistrationBroker,
        manager: DaemonScopedRunLeaseManager, cleanup: () -> Void
    ) {
        let name = String(UUID().uuidString.prefix(8))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        let container = root.appendingPathComponent("c", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let daemon = WikiDaemon(containerDirectory: container)
        let registry = DaemonRunRegistry()
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon, runRegistry: registry)
        let broker = DaemonRunRegistrationBroker(
            registry: registry,
            dispatcher: dispatcher,
            containerDirectory: container)
        let manager = try DaemonScopedRunLeaseManager(
            broker: broker,
            containerDirectory: container)
        return (
            container, broker, manager,
            {
                try? FileManager.default.removeItem(at: root)
            }
        )
    }

    /// The manager mints runs through the broker: two issues produce two
    /// distinct endpoints and capabilities, both with the §6 managed-run
    /// operation classes and the registry's bounded lease cadence.
    @Test func issueProducesDistinctBoundRuns() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let wikiA = WikiDescriptor.make(displayName: "Lease A").id
        let wikiB = WikiDescriptor.make(displayName: "Lease B").id

        let leaseA = try await fixture.manager.issueScopedRun(for: wikiA)
        let leaseB = try await fixture.manager.issueScopedRun(for: wikiB)
        #expect(leaseA.credentials.endpointPath != leaseB.credentials.endpointPath)
        #expect(leaseA.credentials.capability != leaseB.credentials.capability)
        #expect(leaseA.leaseLifetime == DaemonRunRegistry.defaultLeaseLifetime)
        #expect(leaseA.seatbeltInputs.appGroupContainerPath == fixture.container.path)
        #expect(leaseA.seatbeltInputs.daemonEndpointPath.contains(SearchSocketWire.socketFileName))
        let runsDirectory = fixture.container
            .appendingPathComponent(DaemonRunRegistrationBroker.runsDirectoryName, isDirectory: true)
        #expect(leaseA.seatbeltInputs.runsDirectoryPath == runsDirectory.path)
        // Both endpoints are bound and live while the leases are held
        // (existence; the connect-level liveness proof is the sandbox matrix).
        #expect(FileManager.default.fileExists(atPath: leaseA.credentials.endpointPath))
        #expect(FileManager.default.fileExists(atPath: leaseB.credentials.endpointPath))
        #expect(await fixture.manager.liveLeaseCount() == 2)
    }

    /// Revocation unlinks the endpoint and drops the lease→run mapping; a
    /// second revoke settles quietly (idempotent), and renewal AFTER
    /// revocation fails typed (revocation is terminal).
    @Test func revokeIsIdempotentAndTerminal() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let wiki = WikiDescriptor.make(displayName: "Lease R").id
        let lease = try await fixture.manager.issueScopedRun(for: wiki)
        #expect(FileManager.default.fileExists(atPath: lease.credentials.endpointPath))

        await fixture.manager.revokeScopedRun(lease)
        #expect(!FileManager.default.fileExists(atPath: lease.credentials.endpointPath),
                "revocation unlinks the run endpoint")
        #expect(await fixture.manager.liveLeaseCount() == 0)

        // Idempotent: the second revoke settles without error.
        await fixture.manager.revokeScopedRun(lease)
        #expect(await fixture.manager.liveLeaseCount() == 0)

        // Terminal: renewal after revocation fails typed.
        do {
            _ = try await fixture.manager.renewScopedRun(lease)
            Issue.record("renewal after revocation must fail")
        } catch {
            // The registry's invalidTransition (revoked is terminal) or the
            // manager's unknownLease (mapping dropped) — both are the
            // terminal contract.
        }
    }

    /// Revoking one lease leaves the sibling run untouched (no collateral
    /// unlink) — the §10 no-crossover property at the manager level.
    @Test func revokeOneLeavesSiblingUntouched() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let wikiA = WikiDescriptor.make(displayName: "Sibling A").id
        let wikiB = WikiDescriptor.make(displayName: "Sibling B").id
        let leaseA = try await fixture.manager.issueScopedRun(for: wikiA)
        let leaseB = try await fixture.manager.issueScopedRun(for: wikiB)

        await fixture.manager.revokeScopedRun(leaseA)
        #expect(!FileManager.default.fileExists(atPath: leaseA.credentials.endpointPath))
        #expect(FileManager.default.fileExists(atPath: leaseB.credentials.endpointPath),
                "the sibling run's endpoint stays bound")
        #expect(await fixture.manager.liveLeaseCount() == 1)

        await fixture.manager.revokeAll()
        #expect(await fixture.manager.liveLeaseCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: leaseB.credentials.endpointPath))
    }

    /// The manager's issue carries EXACTLY the §6 initial managed-run policy:
    /// reads, edits, and acquisition for the one wiki. Pinned by exercising
    /// the broker-issued lease against the registry's own authorization (the
    /// operation-class set is a constant, so the pin is the constant itself).
    @Test func managedRunOperationClassesAreTheInitialPolicy() {
        #expect(DaemonScopedRunLeaseManager.managedRunOperationClasses == [
            .wikiRead, .wikiEdit, .wikiAcquire,
        ])
    }

    /// The lease struct carries enough for the manager to map back to the
    /// run id — distinct leases map distinctly (the run ids themselves stay
    /// private to the manager).
    @Test func unknownLeaseRenewalFailsTyped() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let wiki = WikiDescriptor.make(displayName: "Unknown").id
        let real = try await fixture.manager.issueScopedRun(for: wiki)
        // A HAND-COOKED lease with the same credentials but different
        // seatbelt inputs must not renew the real run.
        let cooked = AgentScopedRunLease(
            credentials: real.credentials,
            seatbeltInputs: AgentScopedRunSeatbeltInputs(
                appGroupContainerPath: "/elsewhere",
                daemonEndpointPath: real.seatbeltInputs.daemonEndpointPath,
                runsDirectoryPath: real.seatbeltInputs.runsDirectoryPath),
            leaseLifetime: real.leaseLifetime)
        do {
            _ = try await fixture.manager.renewScopedRun(cooked)
            Issue.record("a cooked lease must not renew the real run")
        } catch {
            // unknownLease — the mapping is keyed on the whole lease.
        }
        await fixture.manager.revokeScopedRun(real)
    }
}

// The credential delivery contract (§7): the keys are the spawn contract for
// EVERY adapter shape, the capability never renders into prompts or
// diagnostics, and provider hints can never forge or strip the pair.
@Suite("Scoped run credential delivery", .serialized)
struct AgentScopedRunCredentialDeliveryTests {

    private let credentials = AgentScopedRunCredentials(
        endpointPath: "/group/r/abc123.sock",
        capability: "QUJDREVGR0hJSktMTU5PUA==")

    private func context() -> AgentRunContext {
        AgentRunContext(
            scratchDirectory: URL(fileURLWithPath: "/tmp/scratch", isDirectory: true),
            wikiID: WikiID(rawValue: "01HWIKI"),
            wikictlDirectory: "/app/helpers",
            userPATH: "/usr/bin:/bin",
            scopedRun: credentials)
    }

    /// The dedicated keys ride the PROTECTED overwrite set: a provider env
    /// hint with the same names cannot forge or replace the trusted pair,
    /// and both keys survive into the composed child environment.
    @Test func credentialsRideTheProtectedOverwriteSet() {
        let providerForged = [
            AgentScopedRunCredentials.endpointEnvironmentKey: "/attacker/endpoint.sock",
            AgentScopedRunCredentials.capabilityEnvironmentKey: "FORGED",
            "WIKI_DB": "01HOTHER",
        ]
        let env = context().environment(
            providerEnvironment: providerForged,
            baseEnvironment: ProcessInfo.processInfo.environment)
        #expect(env[AgentScopedRunCredentials.endpointEnvironmentKey] == credentials.endpointPath,
                "a provider hint cannot replace the trusted endpoint")
        #expect(env[AgentScopedRunCredentials.capabilityEnvironmentKey] == credentials.capability,
                "a provider hint cannot replace the trusted capability")
        #expect(env["WIKI_DB"] == "01HWIKI", "the wiki selector stays protected too")
    }

    /// Adapter spawn shapes preserve the keys: whatever `resolveSpawnConfig`
    /// builds from a provider profile (plain binary, npx→bun canonicalized,
    /// env-hint-heavy), `ACPBackend.startProcess` merges the run context's
    /// protected keys LAST — pinned here on the pure composition seam for
    /// the seeded adapter shapes (claude, codex, gemini, an npx/bun adapter).
    /// An adapter process that STRIPS its children's environment is outside
    /// this seam's reach by construction — the CLI fails typed instead.
    @Test func adapterSpawnShapesKeepTheCredentialEnvironment() throws {
        let shapes: [(name: String, executable: String, arguments: [String], hints: [String: String])] = [
            ("claude", "/opt/homebrew/bin/claude", [], [HintKey.acpAgentPath.rawValue: "/opt/homebrew/bin/claude"]),
            ("codex", "/opt/homebrew/bin/codex", [], [HintKey.acpAgentPath.rawValue: "/opt/homebrew/bin/codex"]),
            ("gemini", "/opt/homebrew/bin/gemini", [], [HintKey.acpAgentPath.rawValue: "/opt/homebrew/bin/gemini"]),
            ("npx-adapter", "/opt/homebrew/bin/npx", ["x", "@agentclientprotocol/claude-agent-acp"],
             [HintKey.acpAgentPath.rawValue: "/opt/homebrew/bin/npx", HintKey.acpAgentArgs.rawValue: "x @agentclientprotocol/claude-agent-acp"]),
            ("bun-adapter", "/opt/homebrew/bin/bun", ["x", "@agentclientprotocol/claude-agent-acp"],
             [HintKey.acpAgentPath.rawValue: "/opt/homebrew/bin/bun", HintKey.acpAgentArgs.rawValue: "x @agentclientprotocol/claude-agent-acp"]),
        ]
        for shape in shapes {
            let profile = BackendProfile(
                providerHints: shape.hints,
                scratchDirectory: URL(fileURLWithPath: "/tmp/scratch", isDirectory: true),
                runContext: context())
            let spawn = try #require(ACPBackend.resolveSpawnConfig(from: profile))
            // The spawn keeps its OWN executable shape…
            #expect(spawn.executablePath == shape.hints[HintKey.acpAgentPath.rawValue], Comment(rawValue: shape.name))
            // …and the environment the BACKEND composes for it carries the
            // credential pair through the run context (the composition
            // `startProcess` performs; pure here).
            let composed = context().environment(
                providerEnvironment: spawn.environment,
                baseEnvironment: ProcessInfo.processInfo.environment)
            #expect(composed[AgentScopedRunCredentials.endpointEnvironmentKey] == credentials.endpointPath,
                    Comment(rawValue: "\(shape.name): endpoint key survives the spawn composition"))
            #expect(composed[AgentScopedRunCredentials.capabilityEnvironmentKey] == credentials.capability,
                    Comment(rawValue: "\(shape.name): capability key survives the spawn composition"))
        }
    }

    /// The capability NEVER renders into the prompt context or diagnostics —
    /// §7's exclusion list (prompts, WIKI_STATE.md, transcripts, scratch
    /// scripts all flow from these two render seams).
    @Test func capabilityNeverRendersIntoPromptsOrDiagnostics() {
        let prompt = context().promptContextSection()
        #expect(!prompt.contains(credentials.capability))
        #expect(!prompt.contains(credentials.endpointPath))
        let diagnostics = context().diagnosticDescription
        #expect(!diagnostics.contains(credentials.capability))
        #expect(!diagnostics.contains(credentials.endpointPath))
    }

    /// A context WITHOUT a lease exports neither key (the unscoped path is
    /// byte-unchanged), and `withScratch` preserves the credentials for the
    /// fallback-provider sub-scratch (the lease belongs to the session).
    @Test func absentLeaseExportsNothingAndWithScratchPreserves() {
        var bare = AgentRunContext(
            scratchDirectory: URL(fileURLWithPath: "/tmp/scratch", isDirectory: true),
            wikiID: WikiID(rawValue: "01HWIKI"),
            wikictlDirectory: "/app/helpers",
            userPATH: "/usr/bin:/bin")
        #expect(bare.protectedEnvironment[AgentScopedRunCredentials.endpointEnvironmentKey] == nil)
        #expect(bare.protectedEnvironment[AgentScopedRunCredentials.capabilityEnvironmentKey] == nil)

        bare = context()
        let derived = bare.withScratch(URL(fileURLWithPath: "/tmp/scratch/fallback", isDirectory: true))
        #expect(derived.scopedRun == credentials)
        #expect(derived.protectedEnvironment[AgentScopedRunCredentials.endpointEnvironmentKey]
                == credentials.endpointPath)
    }
}
#endif

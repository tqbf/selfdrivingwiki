#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
import WikiFSCore
@testable import wikid

/// THE PHASE 2 RUNTIME GATE (plans/agent-sandbox-scoping.md §8 + §11 Phase
/// 2), live: real `/usr/bin/sandbox-exec` children against REAL broker-bound
/// endpoints and a REAL fixture daemon. Profile-string assertions prove
/// nothing here — every claim below is an actual connect or an actual file
/// open by a sandboxed process:
///
/// - the sandboxed child CAN connect to its ASSIGNED run endpoint and
///   complete a framed v2 request (credentialed hello → protocol reply);
/// - the child CANNOT connect to the ORDINARY daemon endpoint (EPERM, while
///   that listener is live — a refusal would be ECONNREFUSED, so EPERM is
///   the seatbelt's signature);
/// - the child CANNOT connect to ANOTHER RUN's endpoint (EPERM, live
///   listener), including through a symlink planted in the writable scratch
///   (the matcher resolves the vnode);
/// - direct child access to wiki databases (A and B), the central queue
///   database, the registry JSON, and the WAL sidecar is kernel-denied for
///   reads AND writes;
/// - scratch writes still work (the runtime boundary is intact).
///
/// Gate provenance: the same deny/allow shape was first proven in a raw
/// spike on macOS 27.0.1 (arm64); this suite is the durable, in-tree proof.
/// If the connect-denial probes ever fail on a future macOS, that is the
/// approved fallback decision point (§13.5: global mandatory authentication)
/// — report it; do NOT weaken the profile or ship a substitute.
///
/// Client shape: a small `perl` probe (AF_UNIX connect + length-prefixed
/// frame + JSON reply) because the production CLI resolves ONLY the ordinary
/// endpoint. Endpoint path + capability ride environment keys (the §7
/// dedicated-key direction; Phase 3 owns their final names).
///
/// Policy compliance: `.serialized` + `.timeLimit`; subprocess waits via
/// `AgentRuntimePathTests.waitNonblocking` (never `waitUntilExit`); no
/// sleeps.
@Suite("Scoped sandbox gate (live seatbelt)", .serialized, .timeLimit(.minutes(10)))
struct ScopedSandboxGateTests {

    struct SubprocessTimeout: Error {}

    struct ProcessResult {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
        var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
        var errorText: String { String(decoding: standardError, as: UTF8.self) }
    }

    private static let perlInstalled =
        FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")
    private static let sqlite3Installed =
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3")

    // MARK: - Runner

    private func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration = .seconds(60)
    ) async throws -> ProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let status = try await AgentRuntimePathTests.waitNonblocking(process, timeout: timeout)
        return ProcessResult(
            status: status,
            standardOutput: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            standardError: standardError.fileHandleForReading.readDataToEndOfFile())
    }

    /// Minimal child environment: temp HOME, toolchain PATH, relocated temp
    /// roots. Deliberately NARROWER than the production child environment —
    /// no `WIKI_APP_GROUP_ID`, no wiki selector routing — so a probe can
    /// only reach what its arguments and the profile allow.
    private func baseEnvironment(_ fixture: AgentSandboxProcessTests.Fixture)
        -> [String: String]
    {
        [
            "HOME": fixture.home.path,
            "PATH": "/usr/bin:/bin",
            "TMPDIR": fixture.scratch.appendingPathComponent(".tmp").path,
            "TMPPREFIX": fixture.scratch.appendingPathComponent(".tmp/zsh").path,
        ]
    }

    /// Wrap a spawn in the SCOPED-RUN seatbelt argv for the assigned run.
    private func runScoped(
        _ fixture: AgentSandboxProcessTests.Fixture,
        assigned: DaemonScopedRunHandle,
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: Duration = .seconds(60)
    ) async throws -> ProcessResult {
        let invocation = try fixture.scopedRunInvocationForWikiA(
            runEndpointPath: assigned.endpointPath)
        let wrapped = SandboxProfile.wrappedArguments(
            executablePath: executablePath,
            arguments: arguments,
            invocation: invocation)
        var env = baseEnvironment(fixture)
        for (key, value) in environment { env[key] = value }
        return try await run(
            executablePath: SandboxProfile.sandboxExecutablePath,
            arguments: wrapped,
            environment: env,
            timeout: timeout)
    }

    // MARK: - Probe script

    /// The perl probe: connect → frame a v2 `hello` → read the framed reply
    /// → report. `WIKI_DAEMON_ENDPOINT` names the target; when
    /// `WIKI_DAEMON_CAPABILITY` is set the request carries the authorization
    /// object. One result line, then exit 0 — the LINE is the evidence:
    /// `CONNECT-OK`, `REPLY-OK <v>`, `DENIED errno=<n>`, or an explicit
    /// transport-failure marker (never mistaken for a policy outcome).
    static let probeScript = """
    #!/usr/bin/perl
    use strict;
    use warnings;
    use Socket;
    use JSON::PP ();
    use MIME::Base64 ();

    my $endpoint = $ENV{WIKI_DAEMON_ENDPOINT};
    die "WIKI_DAEMON_ENDPOINT not set\\n" unless defined $endpoint;

    sub readn {
        my ($fh, $n) = @_;
        my $data = '';
        while (length($data) < $n) {
            my $got = sysread($fh, my $buf, $n - length($data));
            return undef unless defined $got && $got > 0;
            $data .= $buf;
        }
        return $data;
    }

    socket(my $s, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    if (!connect($s, sockaddr_un($endpoint))) {
        print "DENIED errno=" . (0 + $!) . "\\n";
        exit 0;
    }
    print "CONNECT-OK\\n";

    my %request = (
        version => 2,
        requestID => "gate-$$",
        family => 'hello',
        operation => 'capabilities',
    );
    if (defined $ENV{WIKI_DAEMON_CAPABILITY}) {
        $request{authorization} = { capability => $ENV{WIKI_DAEMON_CAPABILITY} };
    }
    my $json = JSON::PP->new->encode(\\%request);
    my $frame = pack('N', length $json) . $json;
    if (!defined syswrite($s, $frame)) {
        print "WRITE-FAILED errno=" . (0 + $!) . "\\n";
        exit 0;
    }
    my $header = readn($s, 4);
    my $payload = defined $header ? readn($s, unpack('N', $header)) : undef;
    if (!defined $payload) {
        print "READ-FAILED\\n";
        exit 0;
    }
    my $reply = JSON::PP->new->decode($payload);
    if (ref $reply && defined $reply->{error}) {
        print "REPLY-ERROR " . ($reply->{error}{code} // '?') . "\\n";
        exit 0;
    }
    # The envelope's payload field is Swift `Data` JSON -> a base64 STRING;
    # decode it before reading protocolVersion.
    my $inner = $reply->{payload};
    if (defined $inner && !ref $inner) {
        $inner = JSON::PP->new->decode(MIME::Base64::decode_base64($inner));
    }
    if (ref $inner && ($inner->{protocolVersion} // 0) == 2) {
        print "REPLY-OK 2\\n";
    } else {
        print "REPLY-UNEXPECTED\\n";
    }
    exit 0;
    """

    private func writeProbeScript(
        into fixture: AgentSandboxProcessTests.Fixture
    ) throws -> URL {
        let url = fixture.scratch.appendingPathComponent("gate-probe.pl")
        try Data(Self.probeScript.utf8).write(to: url)
        return url
    }

    /// One fixture world with the daemon, the ordinary listener, and TWO
    /// live runs (A assigned to wiki A, B the foreign run).
    private func makeGateWorld() async throws -> (
        AgentSandboxProcessTests.Fixture, DaemonScopedRunHandle, DaemonScopedRunHandle
    ) {
        // Temp-root container: this suite's probes address explicit paths
        // (no `wikictl`), and a private container keeps the parallel graph
        // from colliding on the shared group-test container's daemon socket.
        let fixture = try AgentSandboxProcessTests.Fixture(containerLocation: .tempRoot)
        do {
            try fixture.startDaemon()
            guard let broker = fixture.runBroker else {
                throw GateWorldError.brokerMissing
            }
            let runA = try await broker.launchScopedRun(
                scope: DaemonRunScope(wikiID: fixture.wikiA.id),
                operationClasses: [.wikiRead, .wikiEdit, .wikiAcquire])
            let runB = try await broker.launchScopedRun(
                scope: DaemonRunScope(wikiID: fixture.wikiB.id),
                operationClasses: [.wikiRead])
            return (fixture, runA, runB)
        } catch {
            fixture.cleanup()
            throw error
        }
    }

    private enum GateWorldError: Error {
        case brokerMissing
    }

    // MARK: - The gate

    @Test(.enabled(if: ScopedSandboxGateTests.perlInstalled))
    func assignedEndpointAllowsConnectAndCompletesRequest() async throws {
        let (fixture, runA, _) = try await makeGateWorld()
        defer { fixture.cleanup() }
        let probe = try writeProbeScript(into: fixture)

        let result = try await runScoped(
            fixture,
            assigned: runA,
            executablePath: "/usr/bin/perl",
            arguments: [probe.path],
            environment: [
                "WIKI_DAEMON_ENDPOINT": runA.endpointPath,
                "WIKI_DAEMON_CAPABILITY": runA.capability.printable,
            ])
        #expect(result.status == 0, "probe crashed: \(result.errorText)")
        #expect(result.outputText.contains("CONNECT-OK"),
                "the assigned endpoint must be connectable (output: \(result.outputText))")
        #expect(result.outputText.contains("REPLY-OK 2"),
                "the framed credentialed request must complete with a v2 reply (output: \(result.outputText), stderr: \(result.errorText))")
        #expect(!result.outputText.contains("REPLY-ERROR"))
    }

    @Test(.enabled(if: ScopedSandboxGateTests.perlInstalled))
    func ordinaryEndpointIsConnectDeniedWhileListenerIsLive() async throws {
        let (fixture, runA, _) = try await makeGateWorld()
        defer { fixture.cleanup() }
        let probe = try writeProbeScript(into: fixture)
        // The ordinary listener IS live: a refusal would be ECONNREFUSED.
        let ordinaryPath = try SearchSocketWire.socketPath(
            inContainerDirectory: fixture.container)
        #expect(FileManager.default.fileExists(atPath: ordinaryPath))

        let result = try await runScoped(
            fixture,
            assigned: runA,
            executablePath: "/usr/bin/perl",
            arguments: [probe.path],
            environment: [
                "WIKI_DAEMON_ENDPOINT": ordinaryPath,
            ])
        #expect(result.status == 0, "probe crashed: \(result.errorText)")
        #expect(result.outputText.contains("DENIED errno=1"),
                "the ordinary endpoint must be seatbelt-denied (EPERM), got: \(result.outputText)")
        #expect(!result.outputText.contains("CONNECT-OK"))
        #expect(!result.outputText.contains("ECONNREFUSED"),
                "ECONNREFUSED would mean the listener was not live, not a policy denial")
    }

    @Test(.enabled(if: ScopedSandboxGateTests.perlInstalled))
    func foreignRunEndpointIsConnectDeniedIncludingViaSymlink() async throws {
        let (fixture, runA, runB) = try await makeGateWorld()
        defer { fixture.cleanup() }
        let probe = try writeProbeScript(into: fixture)
        // The FOREIGN listener IS live (run B, never revoked).
        #expect(FileManager.default.fileExists(atPath: runB.endpointPath))

        // Direct: the child names the foreign endpoint.
        let direct = try await runScoped(
            fixture,
            assigned: runA,
            executablePath: "/usr/bin/perl",
            arguments: [probe.path],
            environment: ["WIKI_DAEMON_ENDPOINT": runB.endpointPath])
        #expect(direct.status == 0, "probe crashed: \(direct.errorText)")
        #expect(direct.outputText.contains("DENIED errno=1"),
                "a foreign run endpoint must be seatbelt-denied, got: \(direct.outputText)")

        // Bypass shape: a symlink FROM a writable, child-readable location
        // to the foreign endpoint. The seatbelt resolves the vnode, so the
        // alias is denied exactly like the real path. The link directory
        // must be SHORT: sockaddr_un carries 103 bytes, and the fixture
        // scratch path alone (~114) would truncate the child's sockaddr
        // into an ENOENT — a path bug masquerading as a policy outcome.
        let aliasRoot = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("gate-\(UUID().uuidString.prefix(8))",
                                   isDirectory: true)
        try FileManager.default.createDirectory(
            at: aliasRoot, withIntermediateDirectories: true)
        defer {
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: aliasRoot)
        }
        let evilLink = aliasRoot.appendingPathComponent("evil.sock")
        try FileManager.default.createSymbolicLink(
            atPath: evilLink.path, withDestinationPath: runB.endpointPath)
        let viaSymlink = try await runScoped(
            fixture,
            assigned: runA,
            executablePath: "/usr/bin/perl",
            arguments: [probe.path],
            environment: ["WIKI_DAEMON_ENDPOINT": evilLink.path])
        #expect(viaSymlink.outputText.contains("DENIED errno=1"),
                "a symlink to a denied endpoint must be denied too, got: \(viaSymlink.outputText)")

        // Control: the same aliasing TO the assigned endpoint connects —
        // the symlink probe denies because of the TARGET, not the link.
        let goodLink = aliasRoot.appendingPathComponent("good.sock")
        try FileManager.default.createSymbolicLink(
            atPath: goodLink.path, withDestinationPath: runA.endpointPath)
        let assignedViaSymlink = try await runScoped(
            fixture,
            assigned: runA,
            executablePath: "/usr/bin/perl",
            arguments: [probe.path],
            environment: [
                "WIKI_DAEMON_ENDPOINT": goodLink.path,
                "WIKI_DAEMON_CAPABILITY": runA.capability.printable,
            ])
        #expect(assignedViaSymlink.outputText.contains("REPLY-OK 2"),
                "the assigned endpoint must stay reachable via an alias, got: \(assignedViaSymlink.outputText)")
    }

    // MARK: - Direct database denial

    @Test(.enabled(if: ScopedSandboxGateTests.sqlite3Installed))
    func directWikiQueueRegistryAccessIsKernelDeniedWhileScratchWritesWork()
        async throws
    {
        let (fixture, runA, _) = try await makeGateWorld()
        defer { fixture.cleanup() }

        let pagesBefore = try fixture.storeA.listPages(sortBy: .lastUpdated)
            .map(\.title)
        let wikiAPath = fixture.container
            .appendingPathComponent(fixture.wikiA.dbFileName, isDirectory: false).path
        let wikiBPath = fixture.container
            .appendingPathComponent(fixture.wikiB.dbFileName, isDirectory: false).path
        let registryPath = fixture.container.appendingPathComponent("wikis.json").path
        let walPath = wikiAPath + "-wal"

        func denyFails(_ label: String, _ executablePath: String, _ arguments: [String])
            async throws -> ProcessResult
        {
            let result = try await runScoped(
                fixture,
                assigned: runA,
                executablePath: executablePath,
                arguments: arguments)
            #expect(result.status != 0,
                    "\(label) must be kernel-denied, but the child exited 0 with stderr: \(result.errorText)")
            return result
        }

        // READS: wiki A, wiki B, the registry JSON, the WAL sidecar.
        let readA = try await denyFails(
            "wiki A sqlite read", "/usr/bin/sqlite3", [wikiAPath, "SELECT count(*) FROM pages;"])
        #expect(readA.errorText.contains("authorization denied"),
                "the seatbelt denial must surface through sqlite3: \(readA.errorText)")
        _ = try await denyFails(
            "wiki B sqlite read", "/usr/bin/sqlite3", [wikiBPath, "SELECT count(*) FROM pages;"])
        let registryRead = try await denyFails(
            "registry JSON read", "/bin/cat", [registryPath])
        #expect(registryRead.errorText.contains("Operation not permitted"),
                "the registry read denial must be the kernel's, got: \(registryRead.errorText)")
        if FileManager.default.fileExists(atPath: walPath) {
            _ = try await denyFails("WAL sidecar read", "/bin/cat", [walPath])
        } else {
            Issue.record("expected a WAL sidecar for the seeded wiki A store")
        }

        // WRITES: wiki A schema change, wiki B schema change, central queue
        // INSERT — the old #1314 write channel, now closed.
        _ = try await denyFails(
            "wiki A sqlite write", "/usr/bin/sqlite3",
            [wikiAPath, "CREATE TABLE gate_probe(x);"])
        _ = try await denyFails(
            "wiki B sqlite write", "/usr/bin/sqlite3",
            [wikiBPath, "CREATE TABLE gate_probe(x);"])
        _ = try await denyFails(
            "queue sqlite write", "/usr/bin/sqlite3",
            [fixture.queueDatabase.path,
             "CREATE TABLE gate_probe(x);"])

        // Parent-side verification: NOTHING landed.
        let pagesAfter = try fixture.storeA.listPages(sortBy: .lastUpdated)
            .map(\.title)
        #expect(pagesAfter == pagesBefore,
                "the denied writes must not have touched wiki A")
        let queue = try QueueStore(databaseURL: fixture.queueDatabase)
        defer { queue.close() }
        #expect(try queue.loadActive(for: .extraction).isEmpty,
                "the denied queue write must not have persisted a row")

        // POSITIVE CONTROL: scratch writes still work — the runtime boundary
        // is intact, and the denials above are the container denies.
        let scratchWrite = try await runScoped(
            fixture,
            assigned: runA,
            executablePath: "/bin/sh",
            arguments: ["-c",
                        "echo gate-ok > '\(fixture.scratch.path)/gate-out.txt' && cat '\(fixture.scratch.path)/gate-out.txt'"])
        #expect(scratchWrite.status == 0,
                "scratch writes must keep working (stderr: \(scratchWrite.errorText))")
        #expect(scratchWrite.outputText.contains("gate-ok"))
    }

    // MARK: - The endpoint allow is the assigned one, not merely "the runs dir"

    @Test(.enabled(if: ScopedSandboxGateTests.perlInstalled))
    func uncredentialedAssignedEndpointStillCompletesAVersionOnlyReply()
        async throws {
        // Connect filtering and capability checking are INDEPENDENT layers:
        // the profile lets the socket through; the DAEMON decides what an
        // uncredentialed request gets (the version-only hello, §9). Proving
        // both keeps the layers honestly separated.
        let (fixture, runA, _) = try await makeGateWorld()
        defer { fixture.cleanup() }
        let probe = try writeProbeScript(into: fixture)
        let result = try await runScoped(
            fixture,
            assigned: runA,
            executablePath: "/usr/bin/perl",
            arguments: [probe.path],
            environment: ["WIKI_DAEMON_ENDPOINT": runA.endpointPath])
        #expect(result.outputText.contains("CONNECT-OK"))
        #expect(result.outputText.contains("REPLY-OK 2"),
                "an uncredentialed hello still completes (version-only), got: \(result.outputText)")
    }
}
#endif

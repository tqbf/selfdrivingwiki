#if os(macOS)
import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiFSEngine

/// The reviewed YouTube package's auxiliary JavaScript runtime (Bun): the
/// exact-revision grant, the login-shell resolution, the pinned version
/// gate, the identity recheck at configuration time, and the guarantee that
/// a missing or unsupported runtime never blocks the primary caption route.
///
/// Every version probe here runs the REAL `AuxiliaryRuntimeVersionProbe`
/// against real temporary executables; the login-shell locator runs for
/// real with its query seam answering the no-PATH outcome. The managed
/// package process is faked at the executor seam exactly like every other
/// provider test — `uv` is never launched offline.
@Suite("YouTube auxiliary runtime (Bun)", .timeLimit(.minutes(2)))
struct YouTubeAuxiliaryRuntimeTests {

    // MARK: - Fixtures

    private func tempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-auxrt-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real executable whose `--version` output is the given line.
    private func makeFakeRuntime(
        versionLine: String,
        in root: URL,
        name: String = "bun"
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        let script = "#!/bin/sh\ncat <<'EOF'\n\(versionLine)\nEOF\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func resolution(for url: URL) throws -> RuntimeCommandResolution {
        guard case .identity(let identity) = RuntimeFileProbe.probe(url) else {
            Issue.record("fixture runtime is not a usable executable: \(url.path)")
            throw ExtractorValidationError.invalidManifest("fixture runtime")
        }
        return RuntimeCommandResolution(
            command: AuxiliaryRuntimePolicies.bun.name,
            source: .loginShell,
            executableURL: url,
            identity: identity,
            description: RuntimePathDescription(
                redactedPath: url.path,
                basename: url.lastPathComponent,
                fingerprint: "fixture"))
    }

    /// A locator whose shell query answers exactly one scripted outcome.
    private final class ScriptedLocator: ExtractorRuntimeLocating, @unchecked Sendable {
        var callCount = 0
        private let outcome: RuntimeCommandOutcome

        init(outcome: RuntimeCommandOutcome) {
            self.outcome = outcome
        }

        func locate(_ command: ExtractorRuntimeName) async -> RuntimeCommandOutcome {
            callCount += 1
            return outcome
        }
    }

    /// The real locator over a shell query that answers "not installed" —
    /// the outcome a login shell produces when the command is absent (no
    /// PATH hit): exit nonzero with empty stdout and no stderr.
    private func commandAbsentLocator() -> RuntimeCommandLocator {
        RuntimeCommandLocator(
            accountShell: { AccountShellRecord(shellPath: "/bin/zsh") },
            launchShellQuery: { _, _, _, _ in
                ShellQueryOutcome(
                    terminationCause: .exited(code: 1),
                    stdout: Data(),
                    stderr: Data())
            },
            environmentOverrides: [:],
            probe: RuntimeFileProbe.probe,
            shellStartupTimeout: .seconds(5),
            diagnostics: DebugLogExtractorDiagnosticsSink())
    }

    // MARK: - Pinned policy

    @Test("the host pins the same Bun minimum the pinned library documents")
    func pinnedMinimumMatchesTheLibrary() {
        // The library-side half of this pair is pinned by the Python
        // offline contract test: BunJsRuntime.MIN_SUPPORTED_VERSION ==
        // (1, 2, 11) at yt-dlp 2026.08.19.
        #expect(AuxiliaryRuntimePolicies.bun.minimumVersion
            == RuntimeSemanticVersion(major: 1, minor: 2, patch: 11))
        #expect(AuxiliaryRuntimePolicies.bun.name.rawValue == "bun")
    }

    // MARK: - Version gate (real probe)

    @Test("Bun 1.2.11 resolves; 1.2.10 and 1.0.31 are rejected")
    func versionGateAcceptsAndRejects() async throws {
        let root = try tempDirectory("version")
        defer { try? FileManager.default.removeItem(at: root) }
        let prober = AuxiliaryRuntimeVersionProbe()

        let current = try resolution(for: try makeFakeRuntime(
            versionLine: "1.2.11", in: root, name: "bun-current"))
        let older = try resolution(for: try makeFakeRuntime(
            versionLine: "1.2.10", in: root, name: "bun-older"))
        let ancient = try resolution(for: try makeFakeRuntime(
            versionLine: "1.0.31", in: root, name: "bun-ancient"))

        let outcome = await ProcessExtractorProvider.resolveAuxiliaryRuntime(
            locator: ScriptedLocator(outcome: .resolved(current)), prober: prober)
        guard case .resolved = outcome else {
            Issue.record("1.2.11 must resolve")
            return
        }

        for rejected in [older, ancient] {
            let rejectedOutcome = await ProcessExtractorProvider.resolveAuxiliaryRuntime(
                locator: ScriptedLocator(outcome: .resolved(rejected)), prober: prober)
            guard case .unavailable(.unsupportedVersion(let reported, let minimum)) = rejectedOutcome else {
                Issue.record("expected an unsupportedVersion outcome")
                continue
            }
            #expect(minimum == "1.2.11")
            #expect(reported == "1.2.10" || reported == "1.0.31")
            // A withheld grant derives no configuration at all.
            #expect(ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
                retained: rejectedOutcome) == nil)
        }
    }

    @Test("a failed version probe is a typed unavailable outcome")
    func failedProbeIsTyped() async throws {
        let root = try tempDirectory("probe-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        // A script that exits nonzero: no usable version line.
        let broken = try makeFakeRuntime(versionLine: "", in: root, name: "bun-broken")
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: broken)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: broken.path)
        let resolved = try resolution(for: broken)

        let outcome = await ProcessExtractorProvider.resolveAuxiliaryRuntime(
            locator: ScriptedLocator(outcome: .resolved(resolved)),
            prober: AuxiliaryRuntimeVersionProbe())

        guard case .unavailable(.versionProbeFailed) = outcome else {
            Issue.record("expected versionProbeFailed")
            return
        }
    }

    // MARK: - No PATH / command absent (AC.4)

    @Test("a no-PATH resolution is a retained failure and derives no grant")
    func bunRuntimeNoPath() async throws {
        let outcome = await ProcessExtractorProvider.resolveAuxiliaryRuntime(
            locator: commandAbsentLocator(),
            prober: AuxiliaryRuntimeVersionProbe())

        guard case .unavailable(.resolutionFailed(.commandAbsent)) = outcome else {
            Issue.record("expected commandAbsent, got \(outcome)")
            return
        }
        // The retained failure yields no configuration: the package's
        // caption fallback then reports its own fixed setup failure, while
        // the primary route is untouched.
        #expect(ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
            retained: outcome) == nil)
    }

    // MARK: - Exact-revision grant

    @Test("a copied identity with a different digest receives no grant")
    func copiedDigestReceivesNoGrant() throws {
        let reviewed = ReviewedExtractorPackages.youtubeTranscript.revision
        let lookalike = ExtractorPackageRevisionID(
            packageID: reviewed.packageID,
            version: reviewed.version,
            digest: try ExtractorPackageDigest(hex: String(repeating: "cd", count: 32)))

        #expect(ProcessExtractorProvider.wantsAuxiliaryRuntime(reviewed))
        #expect(ProcessExtractorProvider.wantsAuxiliaryRuntime(lookalike) == false)
    }

    // MARK: - Identity recheck

    @Test("a changed executable identity withholds the configuration")
    func identityRecheckFailsClosed() throws {
        let root = try tempDirectory("identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeFakeRuntime(versionLine: "1.2.11", in: root)
        let pinned = try resolution(for: url)

        // Same bytes: the grant derives.
        let unchanged = ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
            retained: .resolved(pinned))
        guard case .reviewedYouTubeBunRuntime(let path)? = unchanged else {
            Issue.record("an unchanged executable must derive the grant")
            return
        }
        #expect(path == url.path)

        // Rewritten bytes: the stat identity drifts, the grant is withheld.
        try Data("#!/bin/sh\necho tampered\n".utf8).write(to: url)
        let drifted = ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
            retained: .resolved(pinned))
        #expect(drifted == nil)
    }

    @Test("the derived configuration round-trips through the wire shape")
    func derivedConfigurationRoundTrips() throws {
        let root = try tempDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeFakeRuntime(versionLine: "1.2.11", in: root)
        let pinned = try resolution(for: url)

        let configuration = try #require(
            ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
                retained: .resolved(pinned)))
        let data = try JSONEncoder().encode(configuration)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Exactly the tagged shape the package reads.
        #expect(document["kind"] as? String == "reviewed-youtube-bun-runtime")
        #expect(document["executablePath"] as? String == url.path)
        #expect(document.count == 2)

        let decoded = try JSONDecoder().decode(
            ExtractorOperationConfiguration.self, from: data)
        #expect(decoded == configuration)
    }
}
#endif

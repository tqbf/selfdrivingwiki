import Foundation
import Testing

/// Source audit for the LLM-spawn sandbox contract (issue #1276, AC.1 + AC.6).
///
/// Every production `BackendProfile` constructor that can start an LLM child
/// process must state its sandbox decision with an explicit, non-nil
/// `sandbox:` argument; every direct ACP SDK `Client.launch` site must consume
/// the shared typed sandboxed launch plan (or BE the fail-closed enforcement
/// seam). The audit is intentionally syntax-light but parses each balanced
/// constructor expression — not a fixed line window — so a multi-line
/// constructor with nested parentheses is audited whole.
///
/// Mutation fixtures at the bottom prove the common bypasses fail: an explicit
/// `sandbox: nil`, an omitted `sandbox:`, and a raw `client.launch(` that does
/// not consume the plan.
@Suite("LLM spawn sandbox exhaustiveness")
struct LLMSpawnSandboxExhaustivenessTests {

    // MARK: - Pure scanning helpers (fixture-testable)

    struct Occurrence {
        let fileName: String
        let line: Int
        let text: String
    }

    /// Every balanced `BackendProfile(…)` expression in `source`, each with its
    /// 1-based line and full constructor text. Balanced-paren parsing means a
    /// constructor spanning many lines (or containing nested calls/parens) is
    /// captured in full.
    static func backendProfileConstructors(in source: String, fileName: String) -> [Occurrence] {
        occurrences(of: "BackendProfile(", in: source, fileName: fileName)
    }

    /// Every direct ACP SDK `Client.launch` call expression in `source`. The
    /// SDK client is the documented LLM spawn seam — `client.launch(` (the
    /// receiver is always named `client` in this codebase) is the marker.
    static func clientLaunchCalls(in source: String, fileName: String) -> [Occurrence] {
        occurrences(of: "client.launch(", in: source, fileName: fileName)
    }

    private static func occurrences(of marker: String, in source: String, fileName: String) -> [Occurrence] {
        var results: [Occurrence] = []
        var searchStart = source.startIndex
        while let found = source.range(of: marker, range: searchStart..<source.endIndex) {
            // Walk the balanced expression from the open parenthesis.
            var depth = 0
            var index = found.lowerBound
            var end: String.Index?
            while index < source.endIndex {
                let character = source[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
                index = source.index(after: index)
            }
            guard let end else { break }
            let text = String(source[found.lowerBound...end])
            let line = source[..<found.lowerBound].components(separatedBy: "\n").count
            results.append(Occurrence(fileName: fileName, line: line, text: text))
            searchStart = source.index(after: end)
        }
        return results
    }

    enum SandboxArgument: Equatable {
        /// `sandbox: nil` — an explicit opt-OUT. Never acceptable in a
        /// production LLM constructor.
        case nilLiteral
        /// A non-nil value expression (a `LLMSandboxScratch.sandbox` value, a
        /// resolved invocation, or a builder call).
        case expression(String)
    }

    /// Extract the `sandbox:` argument from a constructor expression, if any.
    /// PURE, fixture-testable.
    static func sandboxArgument(in constructorText: String) -> SandboxArgument? {
        guard let label = constructorText.range(of: "sandbox:") else { return nil }
        let tail = constructorText[label.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.hasPrefix("nil") { return .nilLiteral }
        // The value expression runs to the next top-level separator.
        var depth = 0
        var value = ""
        for character in tail {
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            if character == "," && depth == 0 { break }
            value.append(character)
        }
        return .expression(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The closed list of production `BackendProfile` constructors that DO NOT
    /// carry a sandbox argument. Each entry pins an exact file and a distinctive
    /// source fragment, and carries a reason. When a constructor below gains a
    /// process path, moves, disappears, or is joined by a new unfenced one, the
    /// audit fails and the change needs a human decision.
    static let constructorExemptions: [(fileName: String, fragment: String, reason: String)] = [
        (
            "AgentProviderRuntime.swift",
            "BackendProfile(model: spawn.model?.rawValue, providerHints: spawn.hints)",
            // The NON-summarizer operation stages (chat/planner/executor/
            // finalizer/lint): this runtime-built profile is consumed only for
            // its backend + policy; the launcher layers its wiki-aware write
            // sandbox, typed run context, and CLI profile onto the profile it
            // actually spawns with (AgentLauncher resolveSandboxInvocation).
            // The summarizer stage — the only stage this runtime spawns
            // directly — is fenced in the sibling constructor above.
            "non-summarizer stages receive their sandbox from AgentLauncher before spawn"
        ),
        (
            "ACPProviderModelProbe.swift",
            "BackendProfile(providerHints: hints)",
            // Configuration-only: the profile exists so
            // ACPBackend.resolveSpawnConfig can extract the adapter path/args/
            // env. The probe launch itself consumes the typed sandboxed launch
            // plan built in discoverObservation (sandboxedSpawnPlan).
            "probe launch consumes the typed sandboxed plan, not this profile"
        ),
    ]

    /// Audit one constructor occurrence. Returns the violation message, or nil
    /// when the occurrence states a recognized sandbox decision or matches a
    /// named exemption. PURE, fixture-testable.
    static func violation(for occurrence: Occurrence) -> String? {
        switch sandboxArgument(in: occurrence.text) {
        case .nilLiteral:
            return "explicit `sandbox: nil` — production LLM constructors must name a sandbox (issue #1276)"
        case .expression:
            return nil
        case nil:
            // No sandbox argument at all: acceptable ONLY inside the named
            // exemption list, matched by exact file + fragment.
            if let exemption = constructorExemptions.first(where: {
                $0.fileName == occurrence.fileName && occurrence.text.contains($0.fragment)
            }) {
                _ = exemption.reason // pinned above; matched silently
                return nil
            }
            return "production BackendProfile constructor without an explicit `sandbox:` decision"
        }
    }

    // MARK: - Filesystem helpers

    static func repositorySourcesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/WikiFSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources", isDirectory: true)
    }

    static func swiftFiles(under root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])!
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    // MARK: - AC.1 + AC.6: the production audits

    /// Every `BackendProfile(` under `Sources/` is inventoried, carries an
    /// explicit non-nil sandbox, or is in the named exemption list.
    @Test func productionBackendProfilesDeclareSandboxDecision() throws {
        let sources = Self.repositorySourcesDirectory()
        var all: [Occurrence] = []
        for file in Self.swiftFiles(under: sources) {
            let source = try String(contentsOf: file, encoding: .utf8)
            all.append(contentsOf: Self.backendProfileConstructors(
                in: source,
                fileName: file.lastPathComponent))
        }

        // Closed inventory: the set of production constructor files and their
        // counts is EXACT. A new constructor (fenced or not) must land here —
        // silently adding one fails the count check.
        let expectedCounts: [String: Int] = [
            "AgentLauncher.swift": 6,
            "AgentProviderRuntime.swift": 2,
            "ACPExtractionClient.swift": 1,
            "ACPProviderModelProbe.swift": 1,
        ]
        var actualCounts: [String: Int] = [:]
        for occurrence in all {
            actualCounts[occurrence.fileName, default: 0] += 1
        }
        #expect(actualCounts == expectedCounts,
                "the production BackendProfile constructor inventory changed — audit it (issue #1276)")

        for occurrence in all {
            if let violation = Self.violation(for: occurrence) {
                Issue.record("\(occurrence.fileName):\(occurrence.line) — \(violation)\n\(occurrence.text)")
            }
        }
    }

    /// Every direct ACP SDK `Client.launch` site under `Sources/` consumes the
    /// shared typed sandboxed launch plan — or is the `ACPBackend.startProcess`
    /// enforcement seam itself (pure policy check + plan application).
    @Test func directACPLaunchesUseSandboxPlan() throws {
        let sources = Self.repositorySourcesDirectory()
        var all: [Occurrence] = []
        var fileSources: [String: String] = [:]
        for file in Self.swiftFiles(under: sources) {
            let source = try String(contentsOf: file, encoding: .utf8)
            fileSources[file.lastPathComponent] = source
            all.append(contentsOf: Self.clientLaunchCalls(in: source, fileName: file.lastPathComponent))
        }

        // Closed inventory of direct SDK launches: the ACPBackend enforcement
        // seam and the probe. A third `client.launch` anywhere in production
        // fails here BEFORE it can spawn unsandboxed.
        let expectedCounts: [String: Int] = [
            "ACPBackend.swift": 1,
            "ACPProviderModelProbe.swift": 1,
        ]
        var actualCounts: [String: Int] = [:]
        for occurrence in all {
            actualCounts[occurrence.fileName, default: 0] += 1
        }
        #expect(actualCounts == expectedCounts,
                "a new direct ACP SDK launch site appeared — it must consume the sandboxed launch plan")

        for occurrence in all {
            switch occurrence.fileName {
            case "ACPBackend.swift":
                // The enforcement seam: startProcess must run the pure
                // fail-closed policy check and apply the shared plan builder —
                // not merely mention them.
                let functionSource = try #require(fileSources["ACPBackend.swift"])
                #expect(functionSource.contains("launchPolicyViolation("),
                        "ACPBackend launch site lost the pure fail-closed policy check")
                #expect(functionSource.contains("sandboxedSpawnPlan("),
                        "ACPBackend launch site no longer builds the shared sandboxed plan")
                #expect(occurrence.text.contains("spawnExecutablePath"),
                        "the seam launch must consume the plan-applied spawn values")
            case "ACPProviderModelProbe.swift":
                // The probe launch consumes ONLY the typed plan: executable,
                // wrapped argv, and effective environment all come from it.
                #expect(occurrence.text.contains("plan.executablePath"),
                        "probe launch must take the plan's sandbox-exec executable")
                #expect(occurrence.text.contains("plan.arguments"),
                        "probe launch must take the plan's wrapped argv")
                #expect(occurrence.text.contains("plan.environment"),
                        "probe launch must take the plan's effective environment")
                let probeSource = try #require(fileSources["ACPProviderModelProbe.swift"])
                #expect(probeSource.contains("sandboxedSpawnPlan("),
                        "probe no longer builds the shared sandboxed plan")
                #expect(probeSource.contains("sandboxUsability(SandboxProfile.sandboxExecutablePath)"),
                        "probe lost the direct-seam usability gate")
            default:
                Issue.record("unexpected direct launch in \(occurrence.fileName):\(occurrence.line)")
            }
        }
    }

    // MARK: - Mutation fixtures (AC.6: the bypasses must fail)

    /// A fixture-shaped exemption-free audit run.
    private static func auditFixture(_ source: String) -> [String] {
        Self.backendProfileConstructors(in: source, fileName: "Fixture.swift")
            .compactMap { Self.violation(for: $0) }
    }

    @Test func auditRejectsExplicitNilSandbox() {
        let source = """
        let profile = BackendProfile(
            model: model,
            providerHints: hints,
            scratchDirectory: scratch,
            isReadOnly: true,
            sandbox: nil)
        """
        let violations = Self.auditFixture(source)
        #expect(violations.count == 1, "sandbox: nil must fail the audit")
        #expect(violations.first?.contains("sandbox: nil") == true)
    }

    @Test func auditRejectsOmittedSandboxOutsideExemptions() {
        let source = """
        let profile = BackendProfile(
            providerHints: hints,
            scratchDirectory: scratch,
            isReadOnly: true)
        """
        let violations = Self.auditFixture(source)
        #expect(violations.count == 1, "an omitted sandbox decision must fail the audit")
        #expect(violations.first?.contains("without an explicit `sandbox:`") == true)
    }

    @Test func auditAcceptsRecognizedNonOptionalBuilder() {
        let source = """
        let profile = BackendProfile(
            providerHints: hints,
            scratchDirectory: scratch.directoryURL,
            isReadOnly: true,
            sandbox: scratch.sandbox)
        """
        #expect(Self.auditFixture(source).isEmpty,
                "a recognized non-optional sandbox expression passes")
    }

    @Test func auditParsesMultilineConstructorsWithNestedParens() {
        // The `sandbox:` argument sits past nested parentheses and line breaks
        // — a line-window audit would miss it; the balanced parser must not.
        let source = """
        let profile = BackendProfile(
            providerHints: AgentBackendFactory.providerHints(
                provider: provider,
                resolvedCommand: resolve(["a", "b"]),
                apiKey: nil,
                selectedModelId: nil),
            scratchDirectory: scratch.directoryURL,
            isReadOnly: true,
            sandbox: SandboxProfile.invocation(
                scratch.sandbox,
                addingHomeSubpaths: [".codex"]))
        """
        #expect(Self.auditFixture(source).isEmpty,
                "a nested multi-line constructor is parsed whole and passes")
    }

    @Test func exemptionRejectsWhenFragmentOrFileDrifts() {
        // The exemption matches on file AND fragment — the same unfenced
        // constructor moved to another file (or reworded) fails.
        let moved = Occurrence(
            fileName: "SomewhereElse.swift",
            line: 10,
            text: "BackendProfile(model: spawn.model?.rawValue, providerHints: spawn.hints)")
        #expect(Self.violation(for: moved) != nil,
                "an exempt constructor moved to another file must fail")

        let reworded = Occurrence(
            fileName: "AgentProviderRuntime.swift",
            line: 10,
            text: "BackendProfile(model: spawn.model?.rawValue, providerHints: spawn.hints, debugLogURL: url)")
        #expect(Self.violation(for: reworded) != nil,
                "an exempt constructor that gains arguments must fail and be re-reviewed")
    }

    @Test func rawDirectLaunchFixtureFailsClosedInventory() {
        // A raw direct SDK launch that does not consume the plan would break
        // the closed inventory count when scanned for real. The scanner finds
        // it and the plan-consumption assertions reject its arguments.
        let source = """
        try await client.launch(
            agentPath: spawn.executablePath,
            arguments: spawn.arguments,
            workingDirectory: cwd,
            environment: env)
        """
        let calls = Self.clientLaunchCalls(in: source, fileName: "Fixture.swift")
        #expect(calls.count == 1)
        // Neither the plan fields nor the enforcement-seam markers are
        // present — under `directACPLaunchesUseSandboxPlan` this file would
        // fail both the inventory count and the per-site assertions.
        let text = calls[0].text
        #expect(!text.contains("plan.executablePath"))
        #expect(!text.contains("plan.arguments"))
        #expect(!text.contains("plan.environment"))
    }
}

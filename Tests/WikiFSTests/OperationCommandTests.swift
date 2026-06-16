import Foundation
import Testing
@testable import WikiFSCore

/// Tests for Phase C's deterministic seams: the `WikiOperation` prompts, the
/// `OperationCommand` env/argv/cwd construction (the EXACT `claude -p` flag
/// surface + `wikictl`-on-PATH), and the `PathPreflight`. These are the seams the
/// structural gate verifier relies on — kept pure/injectable so they test without
/// a real `claude -p` run.
struct OperationCommandTests {

    // MARK: - OperationCommand construction

    private func buildIngest(
        wikictlDir: String = "/Apps/WikiFS.app/Contents/Helpers",
        basePATH: String = "/usr/bin:/bin"
    ) -> OperationCommand {
        OperationCommand.build(
            operation: .ingest(sourcePath: "files/by-id/01ABC.pdf"),
            wikiRoot: "/Users/me/Library/CloudStorage/WikiFS-Research",
            wikiID: "01WIKIULID",
            systemPrompt: "You are the maintainer.",
            scratchDirectory: "/tmp/scratch-xyz",
            wikictlDirectory: wikictlDir,
            claudeExecutable: "/opt/homebrew/bin/claude",
            baseEnvironment: ["PATH": basePATH, "HOME": "/Users/me"]
        )
    }

    @Test func usesResolvedClaudeExecutable() {
        #expect(buildIngest().executable == "/opt/homebrew/bin/claude")
    }

    @Test func argumentsCarryPromptAppendSystemPromptAndAllowedTools() {
        let cmd = buildIngest()
        // -p <prompt> --append-system-prompt <prompt> --allowedTools <tools>
        #expect(cmd.arguments[0] == "-p")
        #expect(cmd.arguments[1] == WikiOperation.ingest(sourcePath: "files/by-id/01ABC.pdf").prompt)
        #expect(cmd.arguments[2] == "--append-system-prompt")
        #expect(cmd.arguments[3] == "You are the maintainer.")
        #expect(cmd.arguments[4] == "--allowedTools")
        #expect(cmd.arguments[5] == OperationCommand.allowedTools)
    }

    @Test func allowedToolsScopesWikictlAndReadOnlyShellAndReadTools() {
        let tools = OperationCommand.allowedTools
        // The agent MUST be able to invoke wikictl; everything else is read-only.
        #expect(tools.contains("Bash(wikictl:*)"))
        #expect(tools.contains("Bash(find:*)"))
        #expect(tools.contains("Bash(cat:*)"))
        #expect(tools.contains("Bash(grep:*)"))
        #expect(tools.contains("Bash(printf:*)"))  // for the stdin-piped --body-file - writes
        #expect(tools.contains("Read"))
        #expect(tools.contains("Grep"))
        #expect(tools.contains("Glob"))
        // No broad Bash(*) / Write / Edit — least privilege.
        #expect(!tools.contains("Bash(*)"))
        #expect(!tools.contains("Edit"))
        #expect(!tools.contains("Write"))
    }

    @Test func environmentExportsWikiRootAndWikiDB() {
        let cmd = buildIngest()
        #expect(cmd.environment["WIKI_ROOT"] == "/Users/me/Library/CloudStorage/WikiFS-Research")
        #expect(cmd.environment["WIKI_DB"] == "01WIKIULID")
    }

    @Test func prependsWikictlDirectoryToChildPATH() {
        let cmd = buildIngest(wikictlDir: "/Apps/WikiFS.app/Contents/Helpers", basePATH: "/usr/bin:/bin")
        // The helper dir must come FIRST so `wikictl` resolves, but the base PATH
        // is preserved so find/cat/grep still resolve too.
        #expect(cmd.environment["PATH"] == "/Apps/WikiFS.app/Contents/Helpers:/usr/bin:/bin")
    }

    @Test func cwdIsTheWritableScratchDirNotTheMount() {
        let cmd = buildIngest()
        #expect(cmd.currentDirectoryPath == "/tmp/scratch-xyz")
        // The mount is read-only; the cwd must never be it.
        #expect(cmd.currentDirectoryPath != "/Users/me/Library/CloudStorage/WikiFS-Research")
    }

    @Test func inheritsBaseEnvironment() {
        let cmd = buildIngest()
        #expect(cmd.environment["HOME"] == "/Users/me")
    }

    @Test func eachOperationKindBuildsAValidCommand() {
        for operation: WikiOperation in [
            .ingest(sourcePath: "files/by-id/01X.txt"),
            .query(question: "How does X compare to Y?"),
            .lint,
        ] {
            let cmd = OperationCommand.build(
                operation: operation,
                wikiRoot: "/mount",
                wikiID: "01W",
                systemPrompt: "schema",
                scratchDirectory: "/scratch",
                wikictlDirectory: "/helpers",
                claudeExecutable: "claude",
                baseEnvironment: [:]
            )
            #expect(cmd.arguments[0] == "-p")
            #expect(cmd.arguments[1] == operation.prompt)
            #expect(cmd.environment["WIKI_DB"] == "01W")
        }
    }

    // MARK: - WikiOperation prompts

    @Test func ingestPromptNamesTheSourceAndTheFourWriteSteps() {
        let prompt = WikiOperation.ingest(sourcePath: "files/by-id/01ABC.pdf").prompt
        #expect(prompt.contains("$WIKI_ROOT/files/by-id/01ABC.pdf"))
        #expect(prompt.contains("wikictl page upsert"))
        #expect(prompt.contains("wikictl index set"))
        #expect(prompt.contains("wikictl log append --kind ingest"))
        // Read-after-write rule is present.
        #expect(prompt.contains("wikictl page get"))
    }

    @Test func queryPromptCarriesTheQuestionAndAsksForCitations() {
        let prompt = WikiOperation.query(question: "What is the auth flow?").prompt
        #expect(prompt.contains("What is the auth flow?"))
        #expect(prompt.lowercased().contains("cite"))
    }

    @Test func lintPromptAsksForAHealthReportAndALogEntry() {
        let prompt = WikiOperation.lint.prompt
        #expect(prompt.contains("orphan pages"))
        #expect(prompt.contains("wikictl log append --kind lint"))
    }

    @Test func everyPromptTellsTheAgentNotToPassWikiAndToWriteViaWikictl() {
        for operation: WikiOperation in [
            .ingest(sourcePath: "f"),
            .query(question: "q"),
            .lint,
        ] {
            let prompt = operation.prompt
            #expect(prompt.contains("WIKI_DB"))       // selects the wiki
            #expect(prompt.contains("do NOT pass --wiki"))
            #expect(prompt.contains("read-only"))     // never edit the mount
        }
    }

    @Test func operationKindTitlesAreStable() {
        #expect(WikiOperation.ingest(sourcePath: "f").kind == .ingest)
        #expect(WikiOperation.query(question: "q").kind == .query)
        #expect(WikiOperation.lint.kind == .lint)
        #expect(WikiOperation.Kind.ingest.title == "Ingest")
        #expect(WikiOperation.Kind.query.title == "Query")
        #expect(WikiOperation.Kind.lint.title == "Lint")
    }

    // MARK: - PathPreflight

    @Test func preflightFindsExecutableOnPath() {
        let result = PathPreflight.resolve(
            executable: "claude",
            onPath: "/usr/bin:/opt/homebrew/bin:/bin",
            fileExists: { $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(result == .found(path: "/opt/homebrew/bin/claude"))
    }

    @Test func preflightReportsMissingWhenNotOnPath() {
        let result = PathPreflight.resolve(
            executable: "claude",
            onPath: "/usr/bin:/bin",
            fileExists: { _ in false }
        )
        guard case .missing(let reason) = result else {
            Issue.record("expected .missing")
            return
        }
        #expect(reason.contains("claude"))
        #expect(reason.contains("PATH"))
    }

    @Test func preflightHonorsPathOrderFirstHitWins() {
        let result = PathPreflight.resolve(
            executable: "claude",
            onPath: "/a:/b:/c",
            fileExists: { $0 == "/b/claude" || $0 == "/c/claude" }
        )
        #expect(result == .found(path: "/b/claude"))
    }

    @Test func preflightTestsAbsolutePathDirectlyWithoutPath() {
        let found = PathPreflight.resolve(
            executable: "/opt/claude",
            onPath: "",
            fileExists: { $0 == "/opt/claude" }
        )
        #expect(found == .found(path: "/opt/claude"))

        let missing = PathPreflight.resolve(
            executable: "/opt/claude",
            onPath: "",
            fileExists: { _ in false }
        )
        guard case .missing = missing else {
            Issue.record("expected .missing for absent absolute path")
            return
        }
    }

    @Test func preflightEmptyExecutableIsMissing() {
        let result = PathPreflight.resolve(executable: "", onPath: "/bin", fileExists: { _ in true })
        guard case .missing = result else {
            Issue.record("expected .missing for empty executable")
            return
        }
    }
}

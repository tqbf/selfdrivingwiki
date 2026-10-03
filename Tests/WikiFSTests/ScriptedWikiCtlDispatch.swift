#if os(macOS)
import Foundation
@testable import WikiFSCore
@testable import WikiCtlCore

/// The outcome of one scripted `wikictl` invocation, mirroring the REAL
/// executable's observable contract: exit code, stdout, stderr.
struct ScriptedCLIOutcome: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    /// Exit codes as contracted by `Sources/wikictl/main.swift`: 0 success,
    /// 1 runtime error, 2 usage error, 3 CAS conflict.
    enum Code {
        static let success: Int32 = 0
        static let runtimeFailure: Int32 = 1
        static let usageFailure: Int32 = 2
        static let casConflict: Int32 = 3
    }
}

/// Dispatches raw `wikictl` argv through the PRODUCTION command pipeline —
/// the same `ArgumentParser.parse` → kind-specific `*Command.run` →
/// error-to-exit-code mapping `Sources/wikictl/main.swift` performs — except
/// in-process, against a disposable store, with no subprocess.
///
/// This is the seam phase 5.1 of
/// `plans/wiki-strategies-and-cumulative-ingestion.md` calls the "production
/// CLI command dispatch/upsert seam": a scripted `FakeAgentBackend` action
/// plays the role of the agent typing a `wikictl` command, and the command
/// runs the REAL parse, the REAL `PageCommand`/`LogIndexCommand` dispatch,
/// and the REAL `PageUpsert.upsert` shared write seam. Handing a premerged
/// body straight to the store would bypass all of that and prove nothing
/// about ingestion.
///
/// Fidelity notes (deliberate deltas from the executable, each inert for the
/// command families the scripted pipelines use):
/// - `WIKI_WORKSPACE` / `WIKI_AUTHOR` env application (`applyEnv`) is not
///   mirrored: the test process has no per-spawn env, and scripts pass every
///   option explicitly.
/// - The Tantivy BM25 search leg and the package fence validator are not
///   resolved: scripted pipelines use no `page search` and `validator: nil`
///   is the documented dev/`swift test` semantic of `PageCommand.run`.
enum ScriptedWikiCtl {

    /// The wiki selector value used in scripted argv. The real agent gets a
    /// `--wiki`/`WIKI_DB` selector from its spawn env; in-process the store
    /// is bound directly, so the selector only needs to satisfy the parser.
    static let wikiSelector = "cumulative-ingest-test"

    /// Dispatch `argv` (without the executable name, exactly as the process
    /// layer receives `CommandLine.arguments.dropFirst()`).
    static func dispatch(_ argv: [String], in store: GRDBWikiStore) -> ScriptedCLIOutcome {
        let invocation: ArgumentParser.Invocation
        do {
            invocation = try ArgumentParser.parse(argv, env: { _ in nil })
        } catch let failure as ArgumentParser.Failure {
            return ScriptedCLIOutcome(
                exitCode: ScriptedCLIOutcome.Code.usageFailure,
                stdout: "",
                stderr: "wikictl: \(failure)")
        } catch {
            return ScriptedCLIOutcome(
                exitCode: ScriptedCLIOutcome.Code.usageFailure,
                stdout: "",
                stderr: "wikictl: \(error)")
        }

        do {
            switch invocation.command {
            case .page(let action):
                let result = try PageCommand.run(action, in: store)
                return committed(result)
            case .logAppend(let kind, let title, let note, let source):
                let result = try LogIndexCommand.run(
                    .logAppend(kind: kind, title: title, note: note, source: source),
                    in: store)
                return committed(result)
            default:
                return ScriptedCLIOutcome(
                    exitCode: ScriptedCLIOutcome.Code.runtimeFailure,
                    stdout: "",
                    stderr: "scripted dispatch: unsupported command family for pipeline scripts")
            }
        } catch let conflict as PageConflictError {
            let actual = conflict.actualVersionID?.rawValue ?? "(none)"
            return ScriptedCLIOutcome(
                exitCode: ScriptedCLIOutcome.Code.casConflict,
                stdout: "",
                stderr: "wikictl: CAS conflict on page \(conflict.pageID.rawValue) — "
                    + "expected head \(conflict.expectedVersionID), "
                    + "but actual head is \(actual). "
                    + "Re-read the page, reapply your edit, and retry once.")
        } catch let conflict as PageCreateConflictError {
            // Create-only conflict (phase 4 §4.4): the caller's read found no
            // page under the title, but one exists now. Same exit code 3 as
            // the CAS conflict — the agent re-reads the page, reconciles
            // against its head, and writes with --expect-head. Nothing was
            // written.
            let actual = conflict.actualVersionID?.rawValue ?? "(none)"
            return ScriptedCLIOutcome(
                exitCode: ScriptedCLIOutcome.Code.casConflict,
                stdout: "",
                stderr: "wikictl: create-only conflict on page \(conflict.pageID.rawValue) "
                    + "(\(conflict.title)) — a page now exists under that title "
                    + "(head \(actual)). Read that page, reconcile against its head, "
                    + "and write with --expect-head. Nothing was written.")
        } catch let conflict as PageExpectedTargetMissingError {
            // Expected-head write whose target no longer exists — same exit
            // code 3 family: re-read, reconcile, write again. Nothing was
            // written, and no page was silently created.
            let target = conflict.pageID?.rawValue ?? "title \(conflict.title)"
            return ScriptedCLIOutcome(
                exitCode: ScriptedCLIOutcome.Code.casConflict,
                stdout: "",
                stderr: "wikictl: expected-head target missing — \(target) no longer "
                    + "exists (expected head \(conflict.expectedHead)). "
                    + "Re-read (`page list` / `page get`), reconcile, and write again. "
                    + "Nothing was written.")
        } catch {
            return ScriptedCLIOutcome(
                exitCode: ScriptedCLIOutcome.Code.runtimeFailure,
                stdout: "",
                stderr: "wikictl: \(error)")
        }
    }

    private static func committed(_ result: PageCommand.Result) -> ScriptedCLIOutcome {
        ScriptedCLIOutcome(
            exitCode: ScriptedCLIOutcome.Code.success,
            stdout: result.output,
            stderr: result.stderrOutput ?? "")
    }
}

/// The `page get --json` row shape (`PageCommand.PageGetJSON` is private to
/// WikiCtlCore; the wire shape is the compatibility contract agents parse).
struct ScriptedPageGetJSON: Decodable, Sendable, Equatable {
    let body_markdown: String
    let head_version_id: String?

    static func parse(_ stdout: String) -> ScriptedPageGetJSON? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        return DebugLog.trying("ScriptedPageGetJSON.parse", operation: {
            try JSONDecoder().decode(ScriptedPageGetJSON.self, from: data)
        })
    }
}
#endif // os(macOS)

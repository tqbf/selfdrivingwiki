import Testing
import Foundation

/// Source-audit regression tests for the strict-tier degradation contract
/// (plans/sandbox-agent.md § "Strict summarizer tier"; issue #1276, gap found
/// by the #1279 smoke matrix): a FAILED model summarization — thrown OR nil —
/// must degrade to the default truncation summary, never leave the message
/// unsummarized. `MessageSummarizer.oneShotReply` swallows launch failures and
/// returns nil, so a `guard … else { continue }` on the nil path silently
/// skipped the fallback in both hosts; these tests pin the fix by asserting
/// the nil branch of every `runModelSummarization` writes the truncation
/// fallback, the same way the thrown path does.
///
/// Source-audit (not behavior) because both call sites are `private static`
/// on hosts whose construction requires the full daemon/app wiring; this
/// follows the established convention of `LLMSpawnSandboxExhaustivenessTests`.
@Suite struct SummarizerDegradationContractTests {

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/WikiFSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// The body of `func runModelSummarization(…)` from `file`, or nil when
    /// the file does not define one.
    static func runModelSummarizationBody(in file: URL) throws -> String? {
        let source = try String(contentsOf: file, encoding: .utf8)
        guard let start = source.range(of: "func runModelSummarization(") else { return nil }
        // The function is the last (or close to last) member of its type; a
        // generous slice to the end of file is fine for the assertions below.
        return String(source[start.lowerBound...])
    }

    /// The nil branch of the `guard let … modelSummary(…) else { … }` — the
    /// slice from the guard to the matching `} catch {` — or nil when the
    /// expected shape is not found.
    static func nilBranch(of body: String) -> Substring? {
        guard let guardRange = body.range(of: "guard let") else { return nil }
        guard let catchRange = body.range(of: "} catch {", range: guardRange.upperBound..<body.endIndex) else {
            return nil
        }
        return body[guardRange.lowerBound..<catchRange.lowerBound]
    }

    /// Both hosts' `runModelSummarization` degrade the NIL result to the
    /// truncation fallback — the same contract as the thrown path.
    @Test func nilModelSummaryDegradesToTruncationInBothHosts() throws {
        let hosts = [
            "wikid/DaemonChatHost.swift",
            "WikiFSEngine/AgentOperationRunner.swift",
        ]
        for host in hosts {
            let file = Self.repositoryRoot()
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent(host)
            let body = try #require(try Self.runModelSummarizationBody(in: file), "\(host) must define runModelSummarization")
            let nilBranch = try #require(Self.nilBranch(of: body), "\(host): expected a `guard let … else { … } catch` shape in runModelSummarization")
            #expect(
                nilBranch.contains("writeDefaultSummaries"),
                "\(host): the nil branch of runModelSummarization must write the truncation fallback (never a silent skip)")
        }
    }

    /// The title path already handles nil correctly; pin it so the same gap
    /// cannot appear there.
    @Test func nilModelTitleFallsBackToProvisionalTitle() throws {
        let file = Self.repositoryRoot()
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("wikid", isDirectory: true)
            .appendingPathComponent("DaemonChatHost.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        guard let titleRange = source.range(of: "func refreshChatTitle(") else {
            Issue.record("DaemonChatHost must define refreshChatTitle")
            return
        }
        let body = String(source[titleRange.lowerBound...])
        guard let nilBranch = body.range(of: "} else if currentTitle.isEmpty, let provisional {") else {
            Issue.record("refreshChatTitle must keep a nil-title fallback branch")
            return
        }
        #expect(
            String(body[nilBranch.upperBound...]).contains("setChatTitleIfEmpty"),
            "the nil-title branch must write the provisional title")
    }
}

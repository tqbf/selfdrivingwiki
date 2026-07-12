import Testing
import Foundation
@testable import WikiFSCore

/// Verifies the codegen contract: each `GeneratedPrompts` constant holds the
/// VERBATIM bytes of its `.md` source file under `prompts/`. This catches both
/// generator bugs (raw-string escaping, trailing-newline stripping) and a
/// transposition (wrong `.md` bound to the wrong constant).
///
/// The `.md` dir is resolved from this test file's path (`Tests/WikiFSTests/`
/// → up two → repo root → `prompts/`), so it does not depend on the test cwd.
struct GeneratedPromptsParityTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // WikiFSTests/
            .deletingLastPathComponent()   // Tests/
    }

    private func md(_ name: String) -> String {
        let url = repoRoot().appendingPathComponent("prompts").appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let body = String(data: data, encoding: .utf8)
        else {
            Issue.record("missing or unreadable prompt file: prompts/\(name)")
            return ""
        }
        return body
    }

    @Test func systemPromptDefaultMatchesFile() {
        #expect(GeneratedPrompts.systemPromptDefault == md("system-prompt-default.md"))
    }

    @Test func wikiIndexDefaultMatchesFile() {
        #expect(GeneratedPrompts.wikiIndexDefault == md("wiki-index-default.md"))
    }

    @Test func ingestWriteRuleMatchesFile() {
        #expect(GeneratedPrompts.ingestWriteRule == md("ingest-write-rule.md"))
    }

    @Test func footnoteConclusionsRuleMatchesFile() {
        #expect(GeneratedPrompts.footnoteConclusionsRule == md("footnote-conclusions-rule.md"))
    }

    @Test func answerCitationRuleMatchesFile() {
        #expect(GeneratedPrompts.answerCitationRule == md("answer-citation-rule.md"))
    }

    @Test func digesterPromptMatchesFile() {
        #expect(GeneratedPrompts.digesterPrompt == md("digester-prompt.md"))
    }

    @Test func extractionSystemMatchesFile() {
        #expect(GeneratedPrompts.extractionSystem == md("extraction-system.md"))
    }

    @Test func extractionInstructionMatchesFile() {
        #expect(GeneratedPrompts.extractionInstruction == md("extraction-instruction.md"))
    }

    @Test func sourceReaderDescriptionMatchesFile() {
        #expect(GeneratedPrompts.sourceReaderDescription == md("source-reader-description.md"))
    }

    @Test func dontRediscoverLeafMatchesFile() {
        #expect(GeneratedPrompts.dontRediscoverLeaf == md("dont-rediscover-leaf.md"))
    }

    @Test func wikiTreeRenderMatchesFile() {
        #expect(GeneratedPrompts.wikiTreeRender == md("wiki-tree-render.md"))
    }

    @Test func ingestSingleTaskMatchesFile() {
        #expect(GeneratedPrompts.ingestSingleTask == md("ingest-single-task.md"))
    }

    @Test func ingestCuratorTaskMatchesFile() {
        #expect(GeneratedPrompts.ingestCuratorTask == md("ingest-curator-task.md"))
    }

    @Test func queryTaskMatchesFile() {
        #expect(GeneratedPrompts.queryTask == md("query-task.md"))
    }

    @Test func chatMatchesFile() {
        #expect(GeneratedPrompts.chat == md("chat.md"))
    }

    @Test func lintTaskMatchesFile() {
        #expect(GeneratedPrompts.lintTask == md("lint-task.md"))
    }

    @Test func lintPageTaskMatchesFile() {
        #expect(GeneratedPrompts.lintPageTask == md("lint-page-task.md"))
    }

    // MARK: - AC1.5: prompt templates contain CAS discipline

    @Test func promptsContainCASDiscipline() {
        // The prompts that invoke `page upsert` must teach the agent the
        // read-head → thread-expectation → retry-once discipline (Phase 1).
        let promptsToCheck = [
            ("ingest-executor", GeneratedPrompts.ingestExecutor),
            ("ingest-single-task", GeneratedPrompts.ingestSingleTask),
            ("ingest-curator-task", GeneratedPrompts.ingestCuratorTask),
            ("query-task", GeneratedPrompts.queryTask),
            ("lint-page-task", GeneratedPrompts.lintPageTask),
            ("chat", GeneratedPrompts.chat),
            ("ingest-write-rule", GeneratedPrompts.ingestWriteRule),
        ]
        for (name, prompt) in promptsToCheck {
            #expect(prompt.contains("--expect-head"),
                   "prompt \(name) must mention --expect-head for CAS discipline")
            // At least one of these retry/conflict indicators should appear.
            let hasRetry = prompt.contains("retry") || prompt.contains("re-read") || prompt.contains("re-apply") || prompt.contains("reapply")
            #expect(hasRetry,
                    "prompt \(name) must mention retry-once discipline for CAS")
        }
    }
}

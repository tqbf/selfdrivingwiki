import Testing
import Foundation
@testable import WikiFSCore

/// The agent-facing scripting + processed-source-rewrite contract, asserted
/// against the canonical prompt sources (`prompts/*.md`) and the bundled
/// resource copies (`Sources/WikiFSCore/Resources/Prompts/*.md`)
/// (`plans/sandbox-agent.md` §prompt-contract):
///
/// - canonical and bundled prompt copies stay byte-synchronized (`make prompts`);
/// - Bun/Python scripting is permitted only inside the scratch workspace;
/// - the processed-markdown rewrite flow includes the CAS `--expect-head`;
/// - raw-source immutability and the read-only mount rules stay explicit;
/// - the obsolete categorical heredoc-failure claims are gone.
struct AgentPromptContractTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // <name>.swift
            .deletingLastPathComponent()   // WikiFSTests/
            .deletingLastPathComponent()   // Tests/ → repo root
    }

    private func canonical(_ name: String) -> String? {
        let url = repoRoot()
            .appendingPathComponent("prompts")
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let body = String(data: data, encoding: .utf8) else { return nil }
        return body
    }

    private func bundled(_ name: String) -> String? {
        let url = repoRoot()
            .appendingPathComponent("Sources/WikiFSCore/Resources/Prompts")
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let body = String(data: data, encoding: .utf8) else { return nil }
        return body
    }

    private let agentFacingPrompts = [
        "system-prompt-default.md",
        "chat.md",
        "ingest-write-rule.md",
        "wiki-tree-render.md",
        "ingest-executor.md",
        "ingest-finalizer.md",
        "ingest-single-task.md",
        "ingest-curator-task.md",
        "ingest-planner.md",
    ]

    // MARK: - Resource sync (AC.9)

    @Test func agentPromptsMatchBundledResources() {
        for name in agentFacingPrompts {
            guard let source = canonical(name) else {
                Issue.record("missing canonical prompt: prompts/\(name)")
                continue
            }
            guard let copy = bundled(name) else {
                Issue.record("missing bundled copy: Sources/WikiFSCore/Resources/Prompts/\(name) — run make prompts")
                continue
            }
            #expect(source == copy, "prompts/\(name) drifted from its bundled copy — run make prompts")
        }
    }

    // MARK: - Scripting contract (AC.1 / AC.3 / AC.9)

    @Test func scriptingAndSourceRewriteContractIsConsistent() {
        let system = GeneratedPrompts.systemPromptDefault

        // Process execution + optional runtimes are stated as allowed, and
        // their use is confined to the scratch workspace.
        #expect(system.contains("Process execution is allowed"))
        #expect(system.contains("Bun"))
        #expect(system.contains("Python"))
        #expect(system.contains("SCRATCH WORKSPACE"))
        #expect(system.contains("/bin/sh"), "the POSIX /bin/sh baseline is named")
        // The trusted absolute invocation replaces the bare-command contract.
        #expect(system.contains("RUN ENVIRONMENT"))
        #expect(system.contains("--wiki"))
        #expect(system.contains("convenience"))
        // Heredoc guidance is corrected, not categorically banned.
        #expect(system.contains("heredoc"))
        #expect(system.contains("<<'EOF'"))
    }

    @Test func obsoleteHeredocAndRubyAssumptionsAreAbsent() {
        for name in agentFacingPrompts {
            guard let prompt = canonical(name) else {
                Issue.record("missing canonical prompt: prompts/\(name)")
                continue
            }
            #expect(!prompt.contains("NEVER pipe or heredoc"),
                    "\(name): the categorical heredoc ban is obsolete — temp files are scratch-confined now")
            #expect(!prompt.contains("never shell pipes or heredocs"),
                    "\(name): the categorical heredoc ban is obsolete")
            #expect(!prompt.contains("the sandbox drops"),
                    "\(name): 'the sandbox drops a heredoc body' is false — temp paths live under scratch")
            #expect(!prompt.contains("the sandbox blocks the heredoc"),
                    "\(name): 'the sandbox blocks the heredoc' is false — temp paths live under scratch")
            #expect(!prompt.contains("the body arrives empty"),
                    "\(name): the empty-heredoc-body claim is obsolete")
            #expect(!prompt.contains("do NOT pass --wiki"),
                    "\(name): the --wiki ban is obsolete — the trusted absolute invocation includes --wiki")
        }
    }

    // MARK: - Processed-source rewrite (AC.6 / AC.9)

    @Test func explicitSourceRewriteUsesProcessedMarkdownNotRawBytes() {
        let system = GeneratedPrompts.systemPromptDefault
        let chat = GeneratedPrompts.chat

        for (name, prompt) in [("system-prompt-default", system), ("chat", chat)] {
            // The rewrite flow exists and is CAS-protected.
            #expect(prompt.contains("source edit-markdown"),
                    "\(name) must expose the processed-markdown rewrite command")
            #expect(prompt.contains("--expect-head"),
                    "\(name) rewrite flow must carry the CAS token")
            #expect(prompt.contains("--file"),
                    "\(name) rewrite flow delivers the body from a scratch file")
            // Only-on-request gating + the immutability boundary.
            #expect(prompt.contains("only when"),
                    "\(name) must gate the rewrite on an explicit user request")
            #expect(prompt.lowercased().contains("immutable"),
                    "\(name) must keep the raw-source immutability rule explicit")
            // Terminology: the rewriteable layer is named processed Markdown.
            #expect(prompt.contains("processed Markdown"),
                    "\(name) must distinguish processed Markdown from raw source")
        }

        // The read that feeds the CAS token is documented.
        #expect(system.contains("head_version_id"))
        #expect(chat.contains("head_version_id"))
    }

    // MARK: - Mount + scratch boundaries stay explicit (AC.9)

    @Test func readOnlyMountAndScratchBoundariesRemainExplicit() {
        let system = GeneratedPrompts.systemPromptDefault
        #expect(system.contains("READ-ONLY"), "the mount's read-only rule must stay explicit")
        let writeRule = GeneratedPrompts.ingestWriteRule
        #expect(writeRule.contains("READ-ONLY BY DESIGN"))
        #expect(writeRule.contains("RUN ENVIRONMENT"))
        #expect(writeRule.contains("--wiki"))
    }

    // MARK: - Host-stamped ingest state (#1344 / #1367)

    /// The pipeline ingest task prompts no longer TEACH the `--source`
    /// ritual: the host stamps Ingested at validated-successful job
    /// completion (#1344). Since #1367 each recording step carries one
    /// explicit PROHIBITION line that names the flag — explicit beats
    /// silence, because the mounted system prompt taught `--source` for the
    /// ad-hoc path and task-prompt silence lost to it (issue #1367: 62
    /// mid-run stamps survived a failed job). `--source` may therefore
    /// appear ONLY inside that prohibition sentence. Asserted on BOTH the
    /// canonical sources and the bundled copies the runtime actually loads.
    @Test func pipelineIngestPromptsDropTheSourceRitual() {
        let prohibition = "Never pass `--source` on `wikictl log append`"
        let recordingTaskPromptNames = [
            "ingest-single-task.md",
            "ingest-curator-task.md",
            "ingest-finalizer.md",
        ]
        for name in recordingTaskPromptNames {
            for (copy, origin) in [
                (canonical(name), "prompts/\(name)"),
                (bundled(name), "Sources/WikiFSCore/Resources/Prompts/\(name)"),
            ] {
                guard let prompt = copy else {
                    Issue.record("missing prompt: \(origin)")
                    continue
                }
                #expect(prompt.contains(prohibition),
                        "\(origin): the recording step must carry the explicit --source prohibition (#1367)")
                #expect(!prompt.contains("REQUIRED — it marks"),
                        "\(origin): the --source REQUIRED sentence is retired (#1344)")
                let outsideProhibition = prompt.replacingOccurrences(of: prohibition, with: "")
                #expect(!outsideProhibition.contains("--source"),
                        "\(origin): --source may appear only inside the prohibition line (#1344/#1367)")
            }
        }
        // The planner records nothing (it writes only plan.json), so it keeps
        // #1344's absolute ban: no `--source` mention at all.
        for (copy, origin) in [
            (canonical("ingest-planner.md"), "prompts/ingest-planner.md"),
            (bundled("ingest-planner.md"), "Sources/WikiFSCore/Resources/Prompts/ingest-planner.md"),
        ] {
            guard let planner = copy else {
                Issue.record("missing prompt: \(origin)")
                continue
            }
            #expect(!planner.contains("--source"),
                    "\(origin): the planner never records; --source stays absent (#1344)")
        }
        // The shared write-rule prompt carries the same prohibition at its
        // log-append write list. It also legitimately uses `--source` for
        // `page add` provenance, so only the prohibition itself is pinned.
        for (copy, origin) in [
            (canonical("ingest-write-rule.md"), "prompts/ingest-write-rule.md"),
            (bundled("ingest-write-rule.md"), "Sources/WikiFSCore/Resources/Prompts/ingest-write-rule.md"),
        ] {
            guard let writeRule = copy else {
                Issue.record("missing prompt: \(origin)")
                continue
            }
            #expect(writeRule.contains(prohibition),
                    "\(origin): the write list must carry the explicit --source prohibition (#1367)")
        }
    }

    /// The ad-hoc chat path keeps the agent-asserted `--source` switch:
    /// only pipeline ingests moved to host stamping (#1344).
    @Test func chatPromptKeepsAdHocSourcePath() {
        guard let system = canonical("system-prompt-default.md") else {
            Issue.record("missing canonical prompt: prompts/system-prompt-default.md")
            return
        }
        #expect(system.contains("--source <file-id>"))
        #expect(system.contains("completed-ingest switch"))
    }

    /// #1367: the mounted system prompt keeps the ad-hoc chat allowance but
    /// adds the explicit queued-pipeline prohibition at the same step — the
    /// counter-rule must be as explicit as the teaching it overrides.
    /// Asserted on BOTH the canonical source and the bundled copy.
    @Test func systemPromptProhibitsSourceFlagInQueuedPipelineTasks() {
        for (copy, origin) in [
            (canonical("system-prompt-default.md"), "prompts/system-prompt-default.md"),
            (bundled("system-prompt-default.md"), "Sources/WikiFSCore/Resources/Prompts/system-prompt-default.md"),
        ] {
            guard let system = copy else {
                Issue.record("missing prompt: \(origin)")
                continue
            }
            #expect(system.contains("queued pipeline task"),
                    "\(origin): the prohibition must name the queued pipeline case (#1367)")
            #expect(system.contains("NEVER pass `--source` on `wikictl log append`"),
                    "\(origin): the explicit --source prohibition must stay (#1367)")
            #expect(system.contains("the app marks sources Ingested itself"),
                    "\(origin): the prohibition must say who really stamps (#1367)")
        }
    }

    // MARK: - Cumulative-update contract (wiki strategies phase 4)

    /// The retired executor scope contradiction is gone, and every prompt
    /// surface that writes pages teaches the create-only guard. Asserted on
    /// BOTH the canonical sources and the bundled copies the runtime loads.
    @Test func cumulativeUpdateContractIsConsistent() {
        for (copy, origin) in [
            (canonical("ingest-executor.md"), "prompts/ingest-executor.md"),
            (bundled("ingest-executor.md"), "Resources/Prompts/ingest-executor.md"),
        ] {
            guard let executor = copy else {
                Issue.record("missing prompt: \(origin)")
                continue
            }
            // The blanket existing-page ban ("Do NOT update … or any existing
            // page") contradicted cumulative reconciliation and is retired.
            #expect(!executor.contains("or any existing page"),
                    "\(origin): the blanket existing-page ban must stay retired")
            #expect(executor.contains("--create-only"),
                    "\(origin): the executor must teach the new-page race guard")
            #expect(executor.contains("--expect-head"),
                    "\(origin): the executor must teach the existing-page CAS expectation")
        }
        for name in ["ingest-write-rule.md", "ingest-single-task.md", "ingest-curator-task.md"] {
            for (copy, origin) in [
                (canonical(name), "prompts/\(name)"),
                (bundled(name), "Resources/Prompts/\(name)"),
            ] {
                guard let prompt = copy else {
                    Issue.record("missing prompt: \(origin)")
                    continue
                }
                #expect(prompt.contains("--create-only"),
                        "\(origin): the create-only guard is part of the write contract")
            }
        }
    }

    // MARK: - Strategy-edit authority (chat-only, user-authorized)

    /// The `wikictl strategy read|save|reset` surface is taught to exactly
    /// one agent surface: the interactive chat prompt, gated on the user's
    /// explicit confirmed request. The ingest pipeline prompts and the shared
    /// system prompt must NOT teach the strategy mutation commands — an
    /// ingestion agent processing untrusted source text has no automatic
    /// strategy-edit authority from its prompts. This pins PROMPT PLACEMENT
    /// only; it is not a prompt-injection defense claim — the enforcement
    /// behind the policy remains the write-boundary rules this stack already
    /// states (sources are evidence, never instructions; the task prompt
    /// never widens write permissions).
    @Test func strategyEditAuthorityIsChatOnlyAndUserAuthorized() {
        for (copy, origin) in [
            (canonical("chat.md"), "prompts/chat.md"),
            (bundled("chat.md"), "Resources/Prompts/chat.md"),
        ] {
            guard let chat = copy else {
                Issue.record("missing prompt: \(origin)")
                continue
            }
            // The chat agent knows the commands and the CAS token.
            #expect(chat.contains("wikictl strategy read"),
                    "\(origin): the chat prompt must teach the strategy read")
            #expect(chat.contains("wikictl strategy save"),
                    "\(origin): the chat prompt must teach the strategy save")
            #expect(chat.contains("wikictl strategy reset"),
                    "\(origin): the chat prompt must teach the strategy reset")
            #expect(chat.contains("--expect-revision"),
                    "\(origin): the strategy flow must carry the CAS token")
            // Authorization: only the user's explicit request counts.
            #expect(chat.contains("only when the user asks"),
                    "\(origin): the strategy flow must be user-gated")
            #expect(chat.contains("never itself authorization"),
                    "\(origin): source/page text must be named as non-authorizing")
            // Edits affect future turns; the active turn keeps its capture.
            #expect(chat.contains("NEXT turn"),
                    "\(origin): the future-turn effect must stay explicit")
        }

        // Every other agent-facing prompt — the shared system prompt and the
        // whole ingest pipeline — stays silent on the strategy commands.
        for name in agentFacingPrompts where name != "chat.md" {
            for (copy, origin) in [
                (canonical(name), "prompts/\(name)"),
                (bundled(name), "Resources/Prompts/\(name)"),
            ] {
                guard let prompt = copy else {
                    Issue.record("missing prompt: \(origin)")
                    continue
                }
                for command in ["strategy read", "strategy save", "strategy reset"] {
                    #expect(!prompt.contains(command),
                            "\(origin): only the chat prompt teaches `\(command)` — ingest/source-facing prompts carry no strategy-edit authority")
                }
            }
        }
    }
}

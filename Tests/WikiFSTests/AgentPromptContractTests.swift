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

    // MARK: - Host-stamped ingest state (#1344)

    /// The pipeline ingest task prompts no longer mention `--source` at
    /// all: the host stamps Ingested at validated-successful job
    /// completion, so the agent log-append ritual is retired for pipeline
    /// ingests. (The page-write evidence flag lives in the write-rule and
    /// executor prompts, which are not task prompts.) Asserted on BOTH the
    /// canonical sources and the bundled copies the runtime actually loads.
    @Test func pipelineIngestPromptsDropTheSourceRitual() {
        let taskPromptNames = [
            "ingest-single-task.md",
            "ingest-curator-task.md",
            "ingest-finalizer.md",
            "ingest-planner.md",
        ]
        for name in taskPromptNames {
            for (copy, origin) in [
                (canonical(name), "prompts/\(name)"),
                (bundled(name), "Sources/WikiFSCore/Resources/Prompts/\(name)"),
            ] {
                guard let prompt = copy else {
                    Issue.record("missing prompt: \(origin)")
                    continue
                }
                #expect(!prompt.contains("--source"),
                        "\(origin): pipeline task prompts must not teach the --source ritual (#1344)")
                #expect(!prompt.contains("REQUIRED — it marks"),
                        "\(origin): the --source REQUIRED sentence is retired (#1344)")
            }
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
}

/// Byte-synchronization guard for the canonical → bundled prompt copies of the
/// agent-facing surface. Kept separate from the contract assertions above so a
/// sync drift is one obvious failure, not a cascade.
struct PromptResourceSyncTests {
    private func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    @Test func agentPromptsMatchBundledResources() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // <name>.swift
            .deletingLastPathComponent()   // WikiFSTests/
            .deletingLastPathComponent()   // Tests/ → repo root
        let canonicalDir = root.appendingPathComponent("prompts")
        let bundledDir = root
            .appendingPathComponent("Sources/WikiFSCore/Resources/Prompts")
        let names = [
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
        for name in names {
            let source = read(canonicalDir.appendingPathComponent(name))
            let copy = read(bundledDir.appendingPathComponent(name))
            #expect(source != nil, "missing prompts/\(name)")
            #expect(copy != nil, "missing bundled Prompts/\(name) — run make prompts")
            if let source, let copy {
                #expect(source == copy, "\(name) is out of sync — run make prompts")
            }
        }
    }
}

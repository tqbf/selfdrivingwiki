import Foundation
import Testing
@testable import WikiFSCore

/// AC.1 prompt-safety contract: the system prompt says NOTHING about lint —
/// lint policy lives entirely in the task prompts. The selected-page task is
/// self-contained (validity-only repairs, no creation/deletion/editorial
/// permissions), states its CAS write path explicitly, and the whole-wiki
/// task is report-only.
struct LintPromptContractTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // <name>.swift
            .deletingLastPathComponent()   // WikiFSTests/
            .deletingLastPathComponent()   // Tests/ → repo root
    }

    private func promptFile(_ name: String) -> String? {
        let url = repoRoot()
            .appendingPathComponent("prompts")
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let body = String(data: data, encoding: .utf8) else { return nil }
        return body
    }

    /// Every `prompts/system-prompt-*.md` variant, sorted for determinism.
    private func systemPromptVariants() -> [String] {
        let dir = repoRoot().appendingPathComponent("prompts")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix("system-prompt-") && $0.hasSuffix(".md") }
            .sorted()
    }

    /// The word "lint" as a standalone word, case-insensitive (`\b` so
    /// "blueprint" or "flint" don't trip it).
    private static let lintWord = try! NSRegularExpression(pattern: "\\blints?\\b", options: [.caseInsensitive])

    private func containsLintWord(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return Self.lintWord.firstMatch(in: text, options: [], range: range) != nil
    }

    /// AC.1: system prompts contain no lint reference and no lint command
    /// enumeration. Covers every `system-prompt-*.md` variant.
    @Test func systemHasNoLintPolicy() {
        let variants = systemPromptVariants()
        #expect(!variants.isEmpty, "expected at least one system-prompt variant under prompts/")
        for name in variants {
            let body = promptFile(name)
            #expect(body != nil, "unreadable prompt file: \(name)")
            guard let body else { continue }
            #expect(!containsLintWord(body),
                    "\(name) must not mention lint — lint policy lives in task prompts only")
            // No `--kind` enumeration that lists lint.
            #expect(!body.lowercased().contains("kind ingest|query|lint"),
                    "\(name) must not enumerate the lint log kind")
            #expect(!body.contains("log append --kind lint"),
                    "\(name) must not instruct a lint log append")
        }
    }

    /// The bundled resources match the canonical sources byte-for-byte (the
    /// `make prompts` sync ran; a drifted resource copy would change what
    /// agents actually see).
    @Test func resourcesMatchSources() {
        #expect(GeneratedPrompts.systemPromptDefault == promptFile("system-prompt-default.md"))
        #expect(GeneratedPrompts.lintPageTask == promptFile("lint-page-task.md"))
        #expect(GeneratedPrompts.lintTask == promptFile("lint-task.md"))
    }

    /// The selected-page task is self-contained: it carries the validity
    /// scope, the untrusted-content rule, evidence preservation, no-creation,
    /// no-citation-deletion, no-editorial scope, and exact-tool-selection
    /// rules in its own text — it does not lean on the system prompt for any
    /// of them.
    @Test func selectedPageIsSelfContained() {
        let body = promptFile("lint-page-task.md")
        #expect(body != nil)
        guard let body else { return }

        // Validity-only scope, stated as a boundary.
        #expect(body.contains("VALIDITY"), "the task must scope repairs to validity defects")
        #expect(body.lowercased().contains("editorial"), "the task must exclude editorial changes explicitly")
        // Page creation is denied.
        #expect(body.contains("Do not create pages"))
        // Citation deletion on a missing target is denied.
        #expect(body.lowercased().contains("do not delete a citation"))
        // Untrusted content.
        #expect(body.lowercased().contains("untrusted"))
        // Evidence preservation / no invention.
        #expect(body.lowercased().contains("never invent"))
        // Exact tool selection: the trusted invocation + no mount reads.
        #expect(body.lowercased().contains("run environment") || body.lowercased().contains("trusted"))
        #expect(body.lowercased().contains("never through the"))
        // Bounded CAS recovery named in the task.
        #expect(body.contains("ONCE"), "one recomposition after a conflict")
        #expect(body.lowercased().contains("second conflict"))
    }

    /// The interim (Phase 0) write contract is stated explicitly: full-body
    /// `page add --expect-head` reads head+body in one JSON read, recomposes
    /// once after a conflict against the NEW body, and stops after a second
    /// conflict. (The Phase 3 patch path replaces this section; the flip is
    /// covered by the final contract test.)
    @Test func interimCASPathIsExplicit() {
        let body = promptFile("lint-page-task.md")
        #expect(body != nil)
        guard let body else { return }
        #expect(body.contains("--expect-head"), "the CAS flag must be named")
        #expect(body.contains("--json"), "body+head must come from one JSON read")
        #expect(body.contains("exit code 3"), "the conflict signal must be stated")
        #expect(body.contains("reapply your repairs to the"), "recomposition against the new body, never a replay")
        #expect(body.contains("page add"), "the interim full-body write path is explicit until patches exist")
    }

    /// The whole-wiki task states its own report-only policy: no content
    /// mutation, log append only, untrusted-content rule, evidence with
    /// locations.
    @Test func wholeWikiIsReportOnly() {
        let body = promptFile("lint-task.md")
        #expect(body != nil)
        guard let body else { return }
        #expect(body.contains("REPORT-ONLY"), "the whole-wiki policy is report-only")
        #expect(body.contains("log append --kind lint"), "the task instructs its own lint log entry")
        #expect(body.lowercased().contains("untrusted"), "untrusted-content rule is self-contained")
        #expect(body.lowercased().contains("do not modify"), "no content mutation")
        // It must not rely on the system prompt's (removed) lint workflow.
        #expect(!body.lowercased().contains("from your instructions"))
    }

    // MARK: - Tier-conditioned sections (W5a)

    /// The template carries the tier placeholder so every tier renders a
    /// complete task, and (AC.1) the placeholder mechanism is the ONLY way
    /// tier text enters.
    @Test func templateCarriesTheTierPlaceholder() {
        let body = promptFile("lint-page-task.md")
        #expect(body != nil)
        guard let body else { return }
        #expect(body.contains("{{tierSection}}"), "the tier-conditioned write discipline renders here")
    }

    private func renderedPrompt(mode: LintRunMode) -> String {
        WikiOperation.lintPage(
            page: LintPageIdentity(
                pageID: PageID(rawValue: "01HZPAGE00000000000000000A"),
                title: "Tier Target", headVersionID: nil),
            mode: mode, gateReason: "gate says so",
            reportFilePath: "/tmp/preflight.md", runReportPath: "/tmp/run-report.md",
            stateFilePath: "/tmp/WIKI_STATE.md")
            .prompt(wikiRoot: "/tmp/wiki")
    }

    /// Tier 1 renders the patch-write discipline unchanged — no staging
    /// section, no propose-patch instruction.
    @Test func directRepairRendersNoTierSection() {
        let prompt = renderedPrompt(mode: .directRepair)
        #expect(prompt.contains("Repairs ARE authorized"))
        #expect(prompt.contains("page patch"))
        #expect(prompt.contains("{{tierSection}}") == false,
                "the fill replaced the placeholder")
        #expect(prompt.lowercased().contains("propose-patch") == false,
                "tier 1 never mentions the staging seam")
    }

    /// Tier 2 instructs propose-patch (held for review, never written),
    /// keeps the validity scope, and maps staged repairs to unresolved
    /// outcomes in the run report.
    @Test func stagedProposalRendersTheStagingSection() {
        let prompt = renderedPrompt(mode: .stagedProposal)
        #expect(prompt.contains("Repairs are STAGED, never written"))
        #expect(prompt.contains("page propose-patch"), "the tier-2 submission path is named")
        #expect(prompt.contains("01HZPAGE00000000000000000A"),
                "the propose command carries this run's page id")
        #expect(prompt.contains("Do NOT call `page patch`"))
        #expect(prompt.contains("--lint-receipt"), "the receipt discipline carries over")
        #expect(prompt.lowercased().contains("one staged proposal per page per run"))
        #expect(prompt.contains("staged proposal <id> awaiting human review"),
                "staged repairs are recorded unresolved until a human applies them")
        // Validity-scope rules unchanged.
        #expect(prompt.contains("VALIDITY"))
        #expect(prompt.lowercased().contains("untrusted"))
        #expect(prompt.contains("--expect-head"))
    }

    /// Report-only renders the degradation text — no staging section.
    @Test func reportOnlyRendersNoTierSection() {
        let prompt = renderedPrompt(mode: .reportOnly)
        #expect(prompt.contains("REPORT-ONLY"))
        #expect(prompt.lowercased().contains("propose-patch") == false)
        #expect(prompt.contains("{{tierSection}}") == false)
    }
}

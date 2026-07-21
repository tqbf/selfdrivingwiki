import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

// MARK: - MarkdownLinter

/// Lints wiki-page markdown for cosmetic issues and **auto-fixes** them, using
/// the vendored **markdownlint** library (npm) run in a `JavaScriptCore`
/// `JSContext`.
///
/// **No Node required at runtime.** markdownlint ships as ESM, so it is bundled
/// (one-time, via esbuild) into a single self-contained IIFE
/// (`Resources/markdownlint.bundle.js`, copied into the app bundle as
/// `markdownlint.js` by `build.sh`). At runtime this loads that file into a
/// system `JSContext` and calls `__markdownlint.lint` / `__markdownlint.applyFixes`.
/// `JavaScriptCore` is a macOS system framework — available everywhere, no
/// install, no network.
///
/// **Rule set: cosmetic normalization only.** A curated subset of safe,
/// auto-fixable rules (trailing whitespace, hard tabs, blank-line spacing,
/// etc.); default-off, every enabled rule auto-fixable. Opinionated/structural
/// rules (MD013 line-length, MD040 fenced-language, MD041 first-line-H1,
/// MD001/024/025/033) are excluded. See `defaultConfig`.
///
/// **What it catches vs. misses.** It normalizes whitespace and blank-line
/// structure around headings, fences, lists, and tables; strips trailing
/// whitespace; converts hard tabs to spaces; ensures a single trailing newline.
/// It does NOT enforce structural rules (heading hierarchy, consistent list
/// markers) or line length. The auto-fix is deterministic and respects fenced
/// code blocks (```` ```mermaid ```` contents are never touched).
///
/// **`[[wiki-links]]`** are inert text to markdownlint — no false positives.
///
/// **Two write surfaces** (both mirror `MermaidValidator`):
/// - **Agent path** — `wikictl page add`: `fix()` is applied BEFORE the write
///   (markdown-fix → mermaid-validate → `PageUpsert`). Frictionless under the
///   cosmetic-only config (every rule is auto-fixable).
/// - **In-app path** — `WikiStoreModel.save`: `lint()` computes findings and sets
///   a non-blocking `markdownSaveWarning`; the original text is saved (editor is
///   the human escape hatch).
public final class MarkdownLinter: @unchecked Sendable {

    /// One lint finding from markdownlint.
    public struct LintResult: Equatable, Sendable {
        /// e.g. `["MD009", "no-trailing-spaces"]`.
        public let ruleNames: [String]
        /// 1-based line number.
        public let lineNumber: Int
        /// Human-readable rule description, e.g. "Trailing spaces".
        public let ruleDescription: String
        /// Extra detail, e.g. "Expected: 0 or 2; Actual: 3". `nil` if absent.
        public let errorDetail: String?
        /// The offending text context, e.g. "#Hi". `nil` if absent.
        public let errorContext: String?
        /// `true` when markdownlint provided a `fixInfo` (this finding is
        /// auto-fixable via `applyFixes`).
        public let isFixable: Bool

        /// Short rule id, e.g. "MD009".
        public var ruleID: String { ruleNames.first ?? "?" }
    }

    /// The outcome of `fix(markdown:)`: the normalized text + any findings that
    /// could NOT be auto-fixed (empty under the cosmetic-only config).
    public struct FixOutcome: Equatable {
        public let fixed: String
        public let unfixable: [LintResult]

        public init(fixed: String, unfixable: [LintResult]) {
            self.fixed = fixed
            self.unfixable = unfixable
        }
    }

    // MARK: - Cosmetic-only config

    /// The curated cosmetic-only rule set: `default: false` (turn OFF all rules)
    /// then explicitly enable only the safe, auto-fixable normalizers. Every
    /// enabled rule is auto-fixable, so the agent path's "block on unfixable"
    /// guard is inert in practice (kept wired for a future structural-rules
    /// opt-in). Excluded: MD013 (line-length), MD040 (fenced-language),
    /// MD041 (first-line-H1), MD001/024/025/033.
    public static var defaultConfig: [String: Any] {
        [
            "default": false,
        "MD009": true,   // trailing spaces
        "MD010": true,   // hard tabs
        "MD012": true,   // multiple consecutive blank lines
        "MD018": true, "MD019": true, "MD020": true, "MD021": true,  // space after heading marker
        "MD022": true,   // blanks around headings
        "MD023": true,   // headings must start at the left margin
        "MD027": true,   // multiple spaces after blockquote symbol
        "MD030": true,   // spaces after list markers
        "MD031": true,   // blanks around fences
        "MD032": true,   // blanks around lists
        "MD037": true, "MD038": true, "MD039": true,  // spaces in emphasis/code/links
        "MD047": true,   // file should end with a single newline
        "MD058": true,   // blanks around tables
        ]
    }

    #if canImport(JavaScriptCore)
    private let context: JSContext
    private let lint: JSValue
    private let applyFixes: JSValue
    private let lock = NSLock()
    private let exceptionSink = ExceptionSink()

    /// Load the bundled markdownlint source into a fresh `JSContext`. Returns
    /// `nil` if the source doesn't expose the expected global (e.g. a
    /// corrupt/empty file), so callers degrade gracefully (treat as "no linting
    /// available").
    public init?(jsSource: String) {
        guard !jsSource.isEmpty,
              let context = JSContext() else { return nil }
        let sink = exceptionSink
        context.exceptionHandler = { _, value in
            sink.set(value?.toString())
        }
        // markdownlint is silent in its lint/fix paths, but JSC has no `console`
        // by default — install a no-op one so any stray log can't throw a
        // ReferenceError. A no-arg block ignores any arguments JS passes.
        let noop: @convention(block) () -> Void = {}
        let console = JSValue(newObjectIn: context)
        for name in ["log", "error", "warn", "info", "debug"] {
            console?.setObject(noop, forKeyedSubscript: name as NSCopying & NSObjectProtocol)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSCopying & NSObjectProtocol)

        // markdownlint builds rule-info links with `new URL(...)` at module-load
        // time. JSC has no `URL` global — install a minimal stub that accepts
        // any string (never throws). Safe: none of the enabled cosmetic rules
        // depend on URL validation.
        context.evaluateScript(
            "var URL = function(u){this.href=u;this.origin='';this.protocol='';"
            + "this.host='';this.pathname=u;this.search='';this.hash='';"
            + "this.toString=function(){return u;};};"
        )

        context.evaluateScript(jsSource)
        guard let ml = context.objectForKeyedSubscript("__markdownlint" as NSCopying & NSObjectProtocol),
              ml.isObject,
              let lint = ml.objectForKeyedSubscript("lint" as NSCopying & NSObjectProtocol),
              lint.isObject,
              let applyFixes = ml.objectForKeyedSubscript("applyFixes" as NSCopying & NSObjectProtocol),
              applyFixes.isObject else { return nil }

        self.context = context
        self.lint = lint
        self.applyFixes = applyFixes
    }

    // MARK: - lint

    /// Lint `markdown` with `defaultConfig` and return all findings.
    public func lint(markdown: String) -> [LintResult] {
        lock.lock()
        defer { lock.unlock() }
        exceptionSink.set(nil)
        let options: [String: Any] = [
            "strings": ["content": markdown],
            "config": Self.defaultConfig,
        ]
        guard let result = lint.call(withArguments: [options]),
              let dict = result.toDictionary() as? [String: Any],
              let findings = dict["content"] as? [Any] else {
            return []
        }
        return findings.compactMap { Self.lintResult(from: $0) }
    }

    // MARK: - fix

    /// Auto-fix `markdown`: lint, apply all fixes, and return the normalized text
    /// plus any findings that could NOT be auto-fixed. Under the cosmetic-only
    /// config, `unfixable` is always empty (every rule is auto-fixable).
    public func fix(markdown: String) -> FixOutcome {
        let validatedMarkdown = WikiLinkFixer.applyFixes(to: markdown)

        lock.lock()
        defer { lock.unlock() }
        exceptionSink.set(nil)
        let options: [String: Any] = [
            "strings": ["content": validatedMarkdown],
            "config": Self.defaultConfig,
        ]
        guard let lintResult = lint.call(withArguments: [options]),
              let dict = lintResult.toDictionary() as? [String: Any],
              let findings = dict["content"] as? [Any] else {
            return FixOutcome(fixed: validatedMarkdown, unfixable: [])
        }
        let results = findings.compactMap { Self.lintResult(from: $0) }
        // applyFixes filters internally to findings with fixInfo — passing all
        // findings is safe (unfixable ones are ignored).
        guard let fixedVal = applyFixes.call(withArguments: [validatedMarkdown, findings]),
              let fixed = fixedVal.toString() else {
            return FixOutcome(fixed: validatedMarkdown, unfixable: results.filter { !$0.isFixable })
        }
        let unfixable = results.filter { !$0.isFixable }
        return FixOutcome(fixed: fixed, unfixable: unfixable)
    }

    #else
    // Linux stub: JavaScriptCore is unavailable. All methods are no-ops.
    public init?(jsSource: String) { return nil }
    public func lint(markdown: String) -> [LintResult] { return [] }
    public func fix(markdown: String) -> FixOutcome { FixOutcome(fixed: markdown, unfixable: []) }
    #endif

    // MARK: - describe

    /// Format findings into a human/agent-readable message (one header line +
    /// a line per finding, capped at 15 to keep the in-app banner manageable).
    /// Empty string when there are no findings.
    public static func describe(_ findings: [LintResult]) -> String {
        guard !findings.isEmpty else { return "" }
        let cap = 15
        var lines = ["markdown: \(findings.count) issue(s):"]
        for f in findings.prefix(cap) {
            let detail = f.errorDetail.map { " — \($0)" } ?? ""
            lines.append("  \(f.ruleID) (line \(f.lineNumber)): \(f.ruleDescription)\(detail)")
        }
        if findings.count > cap {
            lines.append("  … and \(findings.count - cap) more")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - bundle resolution

    /// Resolve the vendored `markdownlint.js` for the current runtime and build a
    /// linter, or `nil` when unavailable (dev/`swift test`) so callers skip linting
    /// rather than failing. Tries the main-bundle resource first (in-app editor),
    /// then `../Resources/markdownlint.js` relative to the executable — the same
    /// resolution `MermaidValidator` uses for `merval.js` (the bundled `wikictl`
    /// helper's executable lives in `Contents/Helpers`).
    public static func loadDefault() -> MarkdownLinter? {
        if let url = Bundle.main.url(forResource: "markdownlint", withExtension: "js"),
           let src = try? String(contentsOf: url, encoding: .utf8), !src.isEmpty {
            let linter = MarkdownLinter(jsSource: src)
            DebugLog.store("MarkdownLinter.loadDefault: bundle found at \(url.lastPathComponent), init \(linter != nil ? "OK" : "FAILED")")
            return linter
        }
        // Fallback for the bundled wikictl helper (executable in Contents/Helpers).
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        guard let exeDir else {
            DebugLog.store("MarkdownLinter.loadDefault: no executable URL — linter unavailable")
            return nil
        }
        let candidate = exeDir.deletingLastPathComponent()
            .appendingPathComponent("Resources/markdownlint.js")
        guard let src = try? String(contentsOf: candidate, encoding: .utf8), !src.isEmpty else {
            DebugLog.store("MarkdownLinter.loadDefault: markdownlint.js not found — linter unavailable")
            return nil
        }
        let linter = MarkdownLinter(jsSource: src)
        DebugLog.store("MarkdownLinter.loadDefault: resolved via \(candidate.lastPathComponent), init \(linter != nil ? "OK" : "FAILED")")
        return linter
    }

    /// A process-wide linter built ONCE from the bundled `markdownlint.js` (or
    /// `nil` if unavailable). Use on hot paths (e.g. the debounced editor
    /// autosave) to avoid rebuilding a `JSContext` + re-evaluating the bundle on
    /// every save. `let` → initialized exactly once (thread-safe dispatch_once).
    public static let shared: MarkdownLinter? = MarkdownLinter.loadDefault()

    #if canImport(JavaScriptCore)
    // MARK: - finding mapping

    /// Map a raw markdownlint finding dictionary to `LintResult`.
    private static func lintResult(from raw: Any) -> LintResult? {
        guard let d = raw as? [String: Any] else { return nil }
        let ruleNames = (d["ruleNames"] as? [String]) ?? []
        let lineNumber = (d["lineNumber"] as? Int)
            ?? (d["lineNumber"] as? Double).map(Int.init)
            ?? 0
        let ruleDescription = (d["ruleDescription"] as? String) ?? ""
        let errorDetail = d["errorDetail"] as? String
        let errorContext = d["errorContext"] as? String
        let isFixable = d["fixInfo"] != nil
        return LintResult(
            ruleNames: ruleNames,
            lineNumber: lineNumber,
            ruleDescription: ruleDescription,
            errorDetail: errorDetail,
            errorContext: errorContext,
            isFixable: isFixable
        )
    }
    #endif
}

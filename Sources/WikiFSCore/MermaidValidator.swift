import Foundation
import JavaScriptCore

// MARK: - MermaidValidator

/// Extracts ` ```mermaid ` fenced blocks from markdown and validates each one's
/// syntax with the vendored **merval** library (a zero-dependency Mermaid
/// validator), run in a `JavaScriptCore` `JSContext`.
///
/// **No Node required at runtime.** merval ships as ESM, so it is bundled
/// (one-time, via esbuild) into a single self-contained IIFE
/// (`Resources/merval.bundle.js`, copied into the app bundle as `merval.js` by
/// `build.sh`). At runtime this loads that file into a system `JSContext` and
/// calls `globalThis.__merval.validateMermaid`. `JavaScriptCore` is a macOS
/// system framework — available everywhere, no install, no network.
///
/// **What merval catches vs. misses.** merval validates *structure* — missing
/// arrows, dangling edges, malformed node brackets, unsupported diagram types.
/// It does NOT catch Mermaid's *semantic* gotchas (reserved words like `end`,
/// unquoted special characters). The agent's default system prompt carries those
/// authoring rules; this validator is the structural backstop.
///
/// **Version skew.** merval is validated against Mermaid CLI v11.12.0, while the
/// reader renders with Mermaid 10.9.6. Rare v10/v11 divergences may slip through
/// either way; structural errors are stable across both.
///
/// **Scope of validation here.** `validate(markdown:)` returns one result per
/// mermaid block (valid or not); `invalidBlocks(markdown:)` filters to the bad
/// ones. The block extractor is a lightweight line scanner (no Markdown
/// dependency) handling ``` and ~~~~ fences.
public final class MermaidValidator: @unchecked Sendable {

    /// One block's validation outcome from merval.
    public struct BlockResult: Equatable, Sendable {
        /// 0-based index of the block within the document's mermaid blocks.
        public let index: Int
        public let isValid: Bool
        /// `'flowchart'`, `'sequence'`, … — `nil` if merval couldn't classify it.
        public let diagramType: String?
        public let errors: [Issue]

        public struct Issue: Equatable, Sendable {
            public let line: Int?
            public let code: String?
            public let message: String?
        }
    }

    private let context: JSContext
    private let validate: JSValue
    private let lock = NSLock()
    private let exceptionSink = ExceptionSink()

    /// Load the bundled merval source into a fresh `JSContext`. Returns `nil` if
    /// the source doesn't expose the expected global (e.g. a corrupt/empty file),
    /// so callers degrade gracefully (treat as "no validation available").
    public init?(jsSource: String) {
        guard !jsSource.isEmpty,
              let context = JSContext() else { return nil }
        // Capture the last JS exception (via the shared sink — not `self`, so the
        // context's handler doesn't retain the validator) so a bad input never
        // throws into Swift. Read back in validateSingle for diagnostics.
        let sink = exceptionSink
        context.exceptionHandler = { _, value in
            sink.set(value?.toString())
        }
        // merval is silent in its validate path, but JSC has no `console` by
        // default — install a no-op one so any stray log can't throw a
        // ReferenceError. A no-arg block ignores any arguments JS passes.
        let noop: @convention(block) () -> Void = {}
        let console = JSValue(newObjectIn: context)
        for name in ["log", "error", "warn", "info", "debug"] {
            console?.setObject(noop, forKeyedSubscript: name as NSCopying & NSObjectProtocol)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSCopying & NSObjectProtocol)

        context.evaluateScript(jsSource)
        guard let merval = context.objectForKeyedSubscript("__merval" as NSCopying & NSObjectProtocol),
              let validate = merval.objectForKeyedSubscript("validateMermaid" as NSCopying & NSObjectProtocol),
              validate.isObject else { return nil }

        self.context = context
        self.validate = validate
    }

    /// Validate every ` ```mermaid ` block in `markdown`, returning one result
    /// per block (including valid ones). A JS exception on a block is surfaced as
    /// a single `Issue` (so the page can still save with a clear error).
    public func validate(markdown: String) -> [BlockResult] {
        let blocks = Self.mermaidBlocks(in: markdown)
        lock.lock()
        defer { lock.unlock() }
        return blocks.enumerated().map { idx, source in
            self.validateSingle(at: idx, source: source)
        }
    }

    /// The invalid blocks only — what a save path blocks on.
    public func invalidBlocks(markdown: String) -> [BlockResult] {
        validate(markdown: markdown).filter { !$0.isValid }
    }

    /// Format invalid blocks into a human/agent-readable message (one header
    /// line + a line per error). Empty string when there are no issues.
    public static func describe(_ invalid: [BlockResult]) -> String {
        guard !invalid.isEmpty else { return "" }
        var lines = ["mermaid: \(invalid.count) invalid diagram block(s):"]
        for r in invalid {
            let errs = r.errors.isEmpty
                ? [BlockResult.Issue(line: nil, code: nil, message: "invalid")]
                : r.errors
            for e in errs {
                let wherePart = e.line.map { " (line \($0))" } ?? ""
                let codePart = e.code.map { " [\($0)]" } ?? ""
                lines.append("  block #\(r.index + 1)\(wherePart)\(codePart): \(e.message ?? "invalid")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Resolve the vendored `merval.js` for the current runtime and build a
    /// validator, or `nil` when unavailable (dev/`swift test`) so callers skip
    /// validation rather than failing. Tries the main-bundle resource first
    /// (in-app editor), then `../Resources/merval.js` relative to the executable
    /// — the same resolution the bundled `wikictl` helper uses for
    /// `wiki-identifiers.env` (executable lives in `Contents/Helpers`).
    public static func loadDefault() -> MermaidValidator? {
        if let url = Bundle.main.url(forResource: "merval", withExtension: "js"),
           let src = try? String(contentsOf: url, encoding: .utf8), !src.isEmpty {
            return MermaidValidator(jsSource: src)
        }
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        guard let exeDir else { return nil }
        let candidate = exeDir.deletingLastPathComponent()
            .appendingPathComponent("Resources/merval.js")
        guard let src = try? String(contentsOf: candidate, encoding: .utf8), !src.isEmpty else {
            return nil
        }
        return MermaidValidator(jsSource: src)
    }

    /// A process-wide validator built ONCE from the bundled `merval.js` (or `nil`
    /// if unavailable). Use on hot paths (e.g. the debounced editor autosave) to
    /// avoid rebuilding a `JSContext` + re-evaluating the bundle on every save.
    /// `let` → initialized exactly once (thread-safe dispatch_once).
    public static let shared: MermaidValidator? = MermaidValidator.loadDefault()

    // MARK: - Block extraction (pure, testable)

    /// The inner source of each ` ```mermaid ` (or `~~~mermaid`) fenced block, in
    /// document order. A lightweight CommonMark-ish fence scanner (no `Markdown`
    /// dependency): up to 3 leading spaces, fence char ``` or `~`, the info
    /// string's first token is `mermaid`, closed by a fence of the same char.
    public static func mermaidBlocks(in markdown: String) -> [String] {
        // Normalize line endings first: CRLF (and lone CR, e.g. from pasting)
        // would otherwise leave a trailing `\r` on each line, making the info
        // string `"mermaid\r"` ≠ `"mermaid"` and silently skipping the block —
        // evading the hard wikictl guarantee.
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [String] = []
        var i = 0
        while i < lines.count {
            if let fence = fenceOpening(lines[i]) {
                if fence.language.lowercased() == "mermaid" {
                    var inner: [String] = []
                    i += 1
                    while i < lines.count && !isClosingFence(lines[i], char: fence.char, minLength: fence.length) {
                        inner.append(lines[i])
                        i += 1
                    }
                    blocks.append(inner.joined(separator: "\n"))
                } else {
                    // A non-mermaid fence: skip past its body so its content isn't
                    // mistaken for a mermaid opening later.
                    i += 1
                    while i < lines.count && !isClosingFence(lines[i], char: fence.char, minLength: fence.length) {
                        i += 1
                    }
                }
            }
            i += 1
        }
        return blocks
    }

    private struct Fence { let char: Character; let length: Int; let language: String }

    /// Recognize an opening fence: ≤3 leading spaces, then ≥3 of ``` or `~`, then
    /// an optional info string whose first token is the language.
    private static func fenceOpening(_ line: String) -> Fence? {
        var content = Substring(line)
        var leading = 0
        while leading < 3, content.first == " " { content = content.dropFirst(); leading += 1 }
        guard let char = content.first, char == "`" || char == "~" else { return nil }
        var len = 0
        var rest = content
        while rest.first == char { rest = rest.dropFirst(); len += 1 }
        guard len >= 3 else { return nil }
        let info = rest.trimmingCharacters(in: .whitespaces)
        let language = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return Fence(char: char, length: len, language: language)
    }

    /// A closing fence: same char, at least as long, nothing but spaces after.
    private static func isClosingFence(_ line: String, char: Character, minLength: Int) -> Bool {
        var content = Substring(line)
        var leading = 0
        while leading < 3, content.first == " " { content = content.dropFirst(); leading += 1 }
        var len = 0
        var rest = content
        while rest.first == char { rest = rest.dropFirst(); len += 1 }
        guard len >= minLength else { return false }
        return rest.allSatisfy { $0 == " " }
    }

    // MARK: - JS bridging

    private func validateSingle(at index: Int, source: String) -> BlockResult {
        // Clear the previous block's exception so a later block that ALSO fails
        // to return a result isn't misattributed the earlier block's message.
        exceptionSink.set(nil)
        guard let result = validate.call(withArguments: [source]),
              result.isObject,
              let dict = result.toDictionary() as? [String: Any] else {
            // validateMermaid threw or returned nothing — report as an error so
            // the caller surfaces it rather than silently passing.
            return BlockResult(index: index, isValid: false, diagramType: nil,
                               errors: [.init(line: nil, code: "VALIDATOR_ERROR",
                                              message: jsException())])
        }
        let isValid = (dict["isValid"] as? Bool) ?? false
        let diagramType = (dict["diagramType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let errors = ((dict["errors"] as? [Any]) ?? []).compactMap { MermaidValidator.issue($0) }
        return BlockResult(index: index, isValid: isValid, diagramType: diagramType, errors: errors)
    }

    private static func issue(_ raw: Any) -> BlockResult.Issue? {
        guard let d = raw as? [String: Any] else { return nil }
        let line = (d["line"] as? Int) ?? (d["line"] as? Double).map(Int.init)
        let code = d["code"] as? String
        let message = d["message"] as? String
        return BlockResult.Issue(line: line, code: code, message: message)
    }

    private func jsException() -> String {
        if let exc = exceptionSink.value(), !exc.isEmpty {
            return "mermaid validation failed: \(exc)"
        }
        return "mermaid validation returned no result"
    }
}

/// Thread-safe holder for the most recent `JSContext` exception, so the
/// validator's exception handler (which can't safely capture `self`) can record
/// a failure and `validateSingle` can read it back for diagnostics.
final class ExceptionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String?) { lock.lock(); stored = value; lock.unlock() }
    func value() -> String? { lock.lock(); defer { lock.unlock() }; return stored }
}

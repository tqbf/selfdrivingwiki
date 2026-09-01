import Foundation
import WikiFSTypes
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

// MARK: - FenceSyntaxValidating

/// The format-neutral save-time fence-syntax validation seam. The concrete
/// package-driven service lives in WikiFSCore (it needs the machine package
/// store); store and CLI consumers depend on this protocol only.
public protocol FenceSyntaxValidating: Sendable {
    /// Validate every claimed fence block in `markdown`, returning a
    /// human-readable warning for the invalid ones, or `nil` when there are
    /// none (including when no claiming package is installed).
    func fenceSaveWarning(for markdown: String) -> String?

    /// A one-line notice when `markdown` carries a shape-valid rich fence
    /// alias that no installed package declares a validation contract for,
    /// or `nil` when every present alias is covered (or none is present).
    /// The save proceeds; the notice makes the package-conditional guarantee
    /// visible instead of a silent pass.
    func validationSkipNotice(for markdown: String) -> String?
}

// MARK: - FenceSyntaxValidator

/// A format-neutral JavaScriptCore runner for package-declared fence-syntax
/// validation (manifest revision 3). The host evaluates the declaring
/// package's engine asset (the format's parser) and wrapper asset (which
/// defines the entry function) and calls `entryFunction(text)` with each
/// block. The host carries no format knowledge: which fences exist, what
/// validates them, and how failures read all come from package bytes.
///
/// **Contract with the wrapper asset.** The entry function returns a holder
/// object; the runner flushes the JSC microtask queue after the call, then
/// reads `done` / `isValid` / `diagramType` / `errors` back. `done == false`
/// after the checkpoint means the engine's Promise never settled — treated
/// as a hard error, never as a silent pass.
// The JSContext and JSValue are thread-confined behind `lock` (NSLock):
// every validate call takes the lock, so the context is used by one caller
// at a time. JSValue/JSContext are not Sendable; the lock is the invariant.
// swiftlint:disable:next unchecked_sendable
public final class FenceSyntaxValidator: @unchecked Sendable {

    /// One block's validation outcome from the package entry function.
    public struct BlockResult: Equatable, Sendable {
        /// 0-based index of the block within the document's claimed blocks.
        public let index: Int
        public let isValid: Bool
        /// The format's own diagram-type token when the wrapper reports one.
        public let diagramType: String?
        public let errors: [Issue]

        public init(index: Int, isValid: Bool, diagramType: String?, errors: [Issue]) {
            self.index = index
            self.isValid = isValid
            self.diagramType = diagramType
            self.errors = errors
        }

        public struct Issue: Equatable, Sendable {
            public let line: Int?
            public let code: String?
            public let message: String?

            public init(line: Int?, code: String?, message: String?) {
                self.line = line
                self.code = code
                self.message = message
            }
        }
    }

    #if canImport(JavaScriptCore)
    private let context: JSContext
    private let validate: JSValue
    private let lock = NSLock()
    private let exceptionSink = ExceptionSink()

    /// Evaluate `jsSources` in order in a fresh `JSContext`, then resolve the
    /// entry function by name. Returns `nil` when the function cannot be
    /// resolved (a corrupt or empty wrapper), so callers degrade gracefully
    /// — treat the situation as "no validation available".
    public init?(jsSources: [String], entryFunction: String) {
        guard !entryFunction.isEmpty,
              !jsSources.isEmpty,
              jsSources.allSatisfy({ !$0.isEmpty }),
              let context = JSContext() else { return nil }
        // Capture the last JS exception (via the shared sink — not `self`, so
        // the context's handler doesn't retain the validator) so a bad input
        // never throws into Swift. Read back in validateSingle for
        // diagnostics.
        let sink = exceptionSink
        context.exceptionHandler = { _, value in
            sink.set(value?.toString())
        }
        // Engines are chatty; JSC has no `console` by default — install a
        // no-op one so any stray log can't throw a ReferenceError.
        let noop: @convention(block) () -> Void = {}
        let console = JSValue(newObjectIn: context)
        for name in ["log", "error", "warn", "info", "debug", "trace"] {
            console?.setObject(noop, forKeyedSubscript: name as NSCopying & NSObjectProtocol)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSCopying & NSObjectProtocol)

        for source in jsSources {
            context.evaluateScript(source)
        }

        guard let entry = context.objectForKeyedSubscript(entryFunction as NSCopying & NSObjectProtocol),
              entry.isObject else { return nil }

        self.context = context
        self.validate = entry
    }

    /// Validate every claimed fence block in `markdown`, returning one result
    /// per block (including valid ones). A JS exception on a block is
    /// surfaced as a single `Issue`, so the page can still save with a clear
    /// error.
    public func validate(markdown: String, alias: RendererFenceAlias) -> [BlockResult] {
        let blocks = Self.blocks(in: markdown, alias: alias)
        lock.lock()
        defer { lock.unlock() }
        return blocks.enumerated().map { idx, source in
            self.validateSingle(at: idx, source: source)
        }
    }

    /// The invalid blocks only — what a save path blocks on.
    public func invalidBlocks(markdown: String, alias: RendererFenceAlias) -> [BlockResult] {
        validate(markdown: markdown, alias: alias).filter { !$0.isValid }
    }

    #else
    // Linux stub: JavaScriptCore is unavailable. All methods are no-ops.
    public init?(jsSources: [String], entryFunction: String) { return nil }
    public func validate(markdown: String, alias: RendererFenceAlias) -> [BlockResult] { return [] }
    public func invalidBlocks(markdown: String, alias: RendererFenceAlias) -> [BlockResult] { return [] }
    #endif

    /// Format invalid blocks into a human/agent-readable message (one header
    /// line + a line per error). Empty string when there are no issues.
    public static func describe(alias: RendererFenceAlias, invalid: [BlockResult]) -> String {
        guard !invalid.isEmpty else { return "" }
        var lines = ["\(alias.rawValue): \(invalid.count) invalid diagram block(s):"]
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

    // MARK: - Block extraction (pure, testable)

    /// The inner source of each fenced block claiming `alias`, in document
    /// order. A lightweight CommonMark-ish fence scanner (no `Markdown`
    /// dependency): up to 3 leading spaces, fence char ``` or `~`, the info
    /// string's first token is the claimed alias, closed by a fence of the
    /// same char.
    public static func blocks(in markdown: String, alias: RendererFenceAlias) -> [String] {
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
                if let info = MarkdownFenceInfo.parse(fence.infoString).richInfo,
                   info.alias.rawValue == alias.rawValue {
                    var inner: [String] = []
                    i += 1
                    while i < lines.count && !isClosingFence(lines[i], char: fence.char, minLength: fence.length) {
                        inner.append(lines[i])
                        i += 1
                    }
                    blocks.append(inner.joined(separator: "\n"))
                } else {
                    // A block the alias does not claim: skip past its body so
                    // its content isn't mistaken for a claimed opening later.
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

    private struct Fence { let char: Character; let length: Int; let infoString: String }

    /// Every shape-valid rich-fence alias appearing in `markdown`, in first-
    /// occurrence order, without duplicates. These are the aliases a renderer
    /// package could claim; ordinary programming-language fence labels are
    /// excluded by ``MarkdownFenceInfo.parse`` itself.
    public static func richFenceAliases(in markdown: String) -> [RendererFenceAlias] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var seen = Set<RendererFenceAlias>()
        var ordered: [RendererFenceAlias] = []
        for line in normalized.components(separatedBy: "\n") {
            guard let fence = fenceOpening(line),
                  let info = MarkdownFenceInfo.parse(fence.infoString).richInfo,
                  seen.insert(info.alias).inserted else { continue }
            ordered.append(info.alias)
        }
        return ordered
    }

    /// Recognize an opening fence: ≤3 leading spaces, then ≥3 of ``` or `~`,
    /// then an optional info string whose first token is the language.
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
        return Fence(char: char, length: len, infoString: String(info))
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

    #if canImport(JavaScriptCore)
    // MARK: - JS bridging

    private func validateSingle(at index: Int, source: String) -> BlockResult {
        // Clear the previous block's exception so a later block that ALSO
        // fails to return a result isn't misattributed the earlier block's
        // message.
        exceptionSink.set(nil)
        guard let result = validate.call(withArguments: [source]),
              result.isObject else {
            // The entry function threw synchronously — report as an error so
            // the caller surfaces it rather than silently passing.
            return BlockResult(index: index, isValid: false, diagramType: nil,
                               errors: [.init(line: nil, code: "VALIDATOR_ERROR",
                                              message: jsException())])
        }
        // The engine's Promise callbacks fire during the microtask checkpoint.
        // Without this flush, `done` would still be `false` and every block
        // would look unresolved.
        Self.flushMicrotasks()
        guard let dict = result.toDictionary() as? [String: Any] else {
            return BlockResult(index: index, isValid: false, diagramType: nil,
                               errors: [.init(line: nil, code: "VALIDATOR_ERROR",
                                              message: jsException())])
        }
        let done = (dict["done"] as? Bool) ?? false
        let isValid = (dict["isValid"] as? Bool) ?? false
        let diagramType = (dict["diagramType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let errors = ((dict["errors"] as? [Any]) ?? []).compactMap { Self.issue($0) }
        // `done == false` after the checkpoint means the Promise never settled
        // in one checkpoint — shouldn't happen, but surface it as a hard error
        // rather than silently passing the block.
        if !done {
            return BlockResult(index: index, isValid: false, diagramType: diagramType,
                               errors: [.init(line: nil, code: "VALIDATOR_ERROR",
                                              message: "the engine's validation Promise did not settle")])
        }
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
            return "fence validation failed: \(exc)"
        }
        return "fence validation returned no result"
    }

    // MARK: - JSC microtask checkpoint

    /// Flush the JSC microtask queue so the engine's Promise callbacks fire.
    /// Swift's JavaScriptCore overlay does NOT expose
    /// `JSPerformMicrotaskCheckpoint()`; resolve it via `dlsym` from the
    /// system framework. No-op (silent) if the symbol can't be found — the
    /// validator then reports `VALIDATOR_ERROR`, which is a safer failure mode
    /// than silently approving an unresolved block.
    private static func flushMicrotasks() {
        typealias Fn = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
           let sym = dlsym(handle, "JSPerformMicrotaskCheckpoint") {
            unsafeBitCast(sym, to: Fn.self)()
        }
    }
    #endif
}

#if canImport(JavaScriptCore)
/// Thread-safe holder for the most recent `JSContext` exception, so the
/// validator's exception handler (which can't safely capture `self`) can
/// record a failure and `validateSingle` can read it back for diagnostics.
// The stored exception is guarded by `lock` (NSLock); write-read pairs are
// bracketed by the validator's own lock.
// swiftlint:disable:next unchecked_sendable
final class ExceptionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String?) { lock.lock(); stored = value; lock.unlock() }
    func value() -> String? { lock.lock(); defer { lock.unlock() }; return stored }
}
#endif

private extension MarkdownFenceInfoParseResult {
    /// The rich fence info, or nil for unrecognized/malformed/empty results.
    var richInfo: MarkdownFenceInfo? {
        if case .rich(let info) = self { return info }
        return nil
    }
}

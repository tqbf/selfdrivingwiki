import Foundation
import JavaScriptCore

// MARK: - MermaidValidator

/// Extracts ` ```mermaid ` fenced blocks from markdown and validates each one's
/// syntax with the SAME vendored **mermaid v11.16.0** library that renders
/// diagrams (`Resources/mermaid.min.js`, copied into the app bundle as
/// `mermaid.js` by `build.sh`), run in a `JavaScriptCore` `JSContext`.
///
/// **No Node required at runtime.** mermaid.min.js is a single UMD/IIFE file
/// loaded directly into a system `JSContext`; we call `mermaid.parse(text)` to
/// validate. `JavaScriptCore` is a macOS system framework — available
/// everywhere, no install, no network.
///
/// **Why mermaid.parse() instead of merval.** The previous validator used
/// `merval.bundle.js`, a third-party zero-dependency validator pinned to an
/// older Mermaid grammar. It rejected valid v11 syntax like `A@{ shape: delay }`
/// (the official docs form) so users couldn't save pages with v11 diagrams.
/// Switching to `mermaid.parse()` eliminates the version skew permanently: the
/// validator and the renderer use the EXACT same library, so anything that
/// renders also validates and vice versa.
///
/// **JSC + mermaid gotchas.**
/// 1. `mermaid.parse()` ALWAYS returns a Promise (in JSC and Node). It never
///    throws synchronously. The wrapper installs `.then`/`.catch` callbacks that
///    mutate a holder object, then we **flush the JSC microtask queue** before
///    reading the result. `JSPerformMicrotaskCheckpoint` isn't exposed by the
///    Swift overlay — we `dlsym` it from the system framework.
/// 2. mermaid.min.js bundles DOMPurify, whose factory returns `undefined`
///    without a DOM, then mermaid calls `Zs.addHook(...)` at runtime → crash.
///    A minimal DOM/timer polyfill is installed BEFORE evaluating the mermaid
///    bundle. See `domPolyfillJS`.
///
/// **Leniency note.** mermaid is more lenient than merval was. Things merval
/// rejected (e.g. `flowchart LR\n  A B` — two unconnected words) are now VALID.
/// All genuine syntax errors come back as a single `code: "PARSE_ERROR"` (merval
/// had `MISSING_ARROW`, `UNKNOWN_DIAGRAM_TYPE`, …). The first line of
/// `error.message` is the user-facing summary; a line number is extracted via
/// `/line\s+(\d+)/i` when present.
///
/// **Scope of validation here.** `validate(markdown:)` returns one result per
/// mermaid block (valid or not); `invalidBlocks(markdown:)` filters to the bad
/// ones. The block extractor is a lightweight line scanner (no Markdown
/// dependency) handling ``` and ~~~~ fences.
public final class MermaidValidator: @unchecked Sendable {

    /// One block's validation outcome from mermaid.parse().
    public struct BlockResult: Equatable, Sendable {
        /// 0-based index of the block within the document's mermaid blocks.
        public let index: Int
        public let isValid: Bool
        /// `'flowchart'`, `'sequence'`, … — derived from the first token of the
        /// block's first line. `nil` if the block is empty/blank.
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

    /// Load the bundled mermaid source into a fresh `JSContext` and install the
    /// `globalThis.__merval.validateMermaid` wrapper. Returns `nil` if the
    /// wrapper can't be installed (e.g. a corrupt/empty bundle), so callers
    /// degrade gracefully (treat as "no validation available").
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
        // mermaid is chatty; JSC has no `console` by default — install a no-op
        // one so any stray log can't throw a ReferenceError. A no-arg block
        // ignores any arguments JS passes.
        let noop: @convention(block) () -> Void = {}
        let console = JSValue(newObjectIn: context)
        for name in ["log", "error", "warn", "info", "debug", "trace"] {
            console?.setObject(noop, forKeyedSubscript: name as NSCopying & NSObjectProtocol)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSCopying & NSObjectProtocol)

        // DOM/timer polyfill MUST be installed before evaluating mermaid.min.js
        // — see class doc. Sufficient for DOMPurify's factory to return a usable
        // instance and for mermaid.parse() to run without throwing.
        context.evaluateScript(Self.domPolyfillJS)

        context.evaluateScript(jsSource)

        // initialize is idempotent; wrap in try/catch so a partly-initialized
        // bundle doesn't fail construction (the wrapper still works).
        context.evaluateScript(
            "try { mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' }); } " +
            "catch (e) { /* initialize is idempotent; ignore */ }"
        )

        // Install the validateMermaid wrapper. Sets up a holder `r`, kicks off
        // `mermaid.parse(text)`, attaches Promise callbacks that mutate `r`.
        // The Swift side flushes the microtask queue after calling, then reads
        // `r` back. The wrapper name `__merval` is retained for call-site
        // stability (the global is private to this file).
        context.evaluateScript(Self.wrapperJS)

        guard let merval = context.objectForKeyedSubscript("__merval" as NSCopying & NSObjectProtocol),
              let validate = merval.objectForKeyedSubscript("validateMermaid" as NSCopying & NSObjectProtocol),
              validate.isObject else { return nil }

        self.context = context
        self.validate = validate
    }

    /// Validate every ` ```mermaid ` block in `markdown`, returning one result
    /// per block (including valid ones). A JS exception on a block is surfaced
    /// as a single `Issue` (so the page can still save with a clear error).
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

    /// Resolve the vendored `mermaid.js` for the current runtime and build a
    /// validator, or `nil` when unavailable (dev/`swift test`) so callers skip
    /// validation rather than failing. Tries the main-bundle resource first
    /// (in-app editor), then `../Resources/mermaid.js` relative to the executable
    /// — the same resolution the bundled `wikictl` helper uses for
    /// `wiki-identifiers.env` (executable lives in `Contents/Helpers`). The same
    /// `mermaid.js` is used by the reader for rendering.
    public static func loadDefault() -> MermaidValidator? {
        if let url = Bundle.main.url(forResource: "mermaid", withExtension: "js"),
           let src = try? String(contentsOf: url, encoding: .utf8), !src.isEmpty {
            return MermaidValidator(jsSource: src)
        }
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        guard let exeDir else { return nil }
        let candidate = exeDir.deletingLastPathComponent()
            .appendingPathComponent("Resources/mermaid.js")
        guard let src = try? String(contentsOf: candidate, encoding: .utf8), !src.isEmpty else {
            return nil
        }
        return MermaidValidator(jsSource: src)
    }

    /// A process-wide validator built ONCE from the bundled `mermaid.js` (or
    /// `nil` if unavailable). Use on hot paths (e.g. the debounced editor
    /// autosave) to avoid rebuilding a `JSContext` + re-evaluating the bundle on
    /// every save. `let` → initialized exactly once (thread-safe dispatch_once).
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
              result.isObject else {
            // validateMermaid threw synchronously — report as an error so the
            // caller surfaces it rather than silently passing.
            return BlockResult(index: index, isValid: false, diagramType: nil,
                               errors: [.init(line: nil, code: "VALIDATOR_ERROR",
                                              message: jsException())])
        }
        // mermaid.parse() returns a Promise — its .then/.catch callbacks fire
        // during the microtask checkpoint. Without this flush, `done` would
        // still be `false` and every block would look unresolved.
        Self.flushMicrotasks()
        guard let dict = result.toDictionary() as? [String: Any] else {
            return BlockResult(index: index, isValid: false, diagramType: nil,
                               errors: [.init(line: nil, code: "VALIDATOR_ERROR",
                                              message: jsException())])
        }
        let done = (dict["done"] as? Bool) ?? false
        let isValid = (dict["isValid"] as? Bool) ?? false
        let diagramType = (dict["diagramType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let errors = ((dict["errors"] as? [Any]) ?? []).compactMap { MermaidValidator.issue($0) }
        // `done == false` after the checkpoint means the Promise never settled
        // in one checkpoint — shouldn't happen, but surface it as a hard error
        // rather than silently passing the block.
        if !done {
            return BlockResult(index: index, isValid: false, diagramType: diagramType,
                               errors: [.init(line: nil, code: "VALIDATOR_ERROR",
                                              message: "mermaid.parse() Promise did not settle")])
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
            return "mermaid validation failed: \(exc)"
        }
        return "mermaid validation returned no result"
    }

    // MARK: - JSC microtask checkpoint

    /// Flush the JSC microtask queue so `mermaid.parse()`'s Promise callbacks
    /// fire. Swift's JavaScriptCore overlay does NOT expose
    /// `JSPerformMicrotaskCheckpoint()`; resolve it via `dlsym` from the system
    /// framework. No-op (silent) if the symbol can't be found — the validator
    /// then reports `VALIDATOR_ERROR`, which is a safer failure mode than
    /// silently approving an unresolved block.
    private static func flushMicrotasks() {
        typealias Fn = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
           let sym = dlsym(handle, "JSPerformMicrotaskCheckpoint") {
            unsafeBitCast(sym, to: Fn.self)()
        }
    }

    // MARK: - JS sources (DOM polyfill + validateMermaid wrapper)

    /// Minimal DOM/timer/window polyfill sufficient for mermaid.min.js
    /// (which bundles DOMPurify) to load and run `mermaid.parse()` in a bare
    /// JSContext. Verified working — see `tmp/mermaid-test/test_polyfill.swift`.
    /// Keep in sync with that scratch test if mermaid ever needs more stubs.
    private static let domPolyfillJS = """
(function(){
  // JSC has NO timer functions by default — install no-op stubs.
  globalThis.__timers = globalThis.__timers || { nextId: 1 };
  globalThis.setTimeout = function(fn){ var id = globalThis.__timers.nextId++; return id; };
  globalThis.clearTimeout = function(id){};
  globalThis.setInterval = function(fn){ var id = globalThis.__timers.nextId++; return id; };
  globalThis.clearInterval = function(id){};
  // structuredClone — needed by some diagram types (e.g. pie). JSON round-trip
  // is sufficient for mermaid's internal use.
  if (typeof globalThis.structuredClone !== 'function') {
    globalThis.structuredClone = function(o){ return JSON.parse(JSON.stringify(o)); };
  }
  function Noop(){}
  function makeNode(tag){
    var node = {
      tagName: (tag||'').toUpperCase(),
      nodeName: (tag||'').toUpperCase(),
      nodeType: 1,
      children: [], childNodes: [],
      attributes: {}, style: {},
      classList: { add: Noop, remove: Noop, contains: function(){ return false; }, toggle: Noop },
      getAttribute: function(k){ return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
      setAttribute: function(k,v){ this.attributes[k] = String(v); },
      removeAttribute: function(k){ delete this.attributes[k]; },
      hasAttribute: function(k){ return Object.prototype.hasOwnProperty.call(this.attributes, k); },
      appendChild: function(c){ this.children.push(c); this.childNodes.push(c); c.parentNode = this; return c; },
      removeChild: function(c){ var i = this.children.indexOf(c); if(i>=0){ this.children.splice(i,1); this.childNodes.splice(i,1);} return c; },
      insertBefore: function(c,r){ this.appendChild(c); return c; },
      replaceChild: function(n,o){ return o; },
      cloneNode: function(){ return makeNode(this.tagName); },
      querySelectorAll: function(){ return []; },
      querySelector: function(){ return null; },
      addEventListener: Noop, removeEventListener: Noop,
      textContent: '', innerHTML: '', outerHTML: '',
      firstChild: null, lastChild: null, parentNode: null,
      ownerDocument: null
    };
    return node;
  }
  var emptyDoc = {
    nodeType: 9,
    documentElement: makeNode('html'),
    head: makeNode('head'),
    body: makeNode('body'),
    createElement: makeNode,
    createElementNS: function(ns,tag){ return makeNode(tag); },
    createTextNode: function(t){ return { nodeType:3, nodeValue: String(t), textContent: String(t) }; },
    createComment: function(t){ return { nodeType:8, nodeValue: String(t) }; },
    createDocumentFragment: function(){ return makeNode('fragment'); },
    getElementById: function(){ return null; },
    getElementsByTagName: function(){ return []; },
    getElementsByClassName: function(){ return []; },
    querySelector: function(){ return null; },
    querySelectorAll: function(){ return []; },
    addEventListener: Noop, removeEventListener: Noop,
    implementation: {
      createHTMLDocument: function(){ return emptyDoc; },
      createDocument: function(){ return emptyDoc; },
      hasFeature: function(){ return true; }
    },
    defaultView: null
  };
  emptyDoc.defaultView = null;
  var win = {
    document: emptyDoc,
    Document: Noop, Node: Noop, Element: Noop,
    addEventListener: Noop, removeEventListener: Noop,
    navigator: { userAgent: 'jsc-polyfill' },
    location: { href: 'about:blank', protocol: 'about:' },
    matchMedia: function(){ return { matches: false, addListener: Noop, removeListener: Noop, addEventListener: Noop, removeEventListener: Noop }; },
    requestAnimationFrame: function(cb){ return setTimeout(function(){ cb(Date.now()); }, 0); },
    cancelAnimationFrame: function(){},
    getComputedStyle: function(){ return { getPropertyValue: function(){ return ''; } }; },
    TextEncoder: function(){
      this.encode = function(s){
        var bytes = [];
        for (var i = 0; i < s.length; i++) {
          var c = s.charCodeAt(i);
          if (c < 0x80) bytes.push(c);
          else if (c < 0x800) { bytes.push(0xC0|(c>>6), 0x80|(c&0x3F)); }
          else { bytes.push(0xE0|(c>>12), 0x80|((c>>6)&0x3F), 0x80|(c&0x3F)); }
        }
        return { length: bytes.length, buffer: new Uint8Array(bytes).buffer };
      };
    },
    TextDecoder: function(){ this.decode = function(){ return ''; }; },
    setTimeout: setTimeout, clearTimeout: clearTimeout,
    setInterval: setInterval, clearInterval: clearInterval,
    Map: Map, Set: Set, Promise: Promise, Uint8Array: Uint8Array
  };
  emptyDoc.defaultView = win;
  globalThis.window = win;
  globalThis.document = emptyDoc;
  globalThis.TextEncoder = win.TextEncoder;
  globalThis.TextDecoder = win.TextDecoder;
  globalThis.navigator = win.navigator;
  globalThis.location = win.location;
  globalThis.requestAnimationFrame = win.requestAnimationFrame;
  globalThis.cancelAnimationFrame = win.cancelAnimationFrame;
  globalThis.matchMedia = win.matchMedia;
  globalThis.self = win;
})();
"""

    /// The `globalThis.__merval.validateMermaid(text)` wrapper. Returns a holder
    /// object `r`; the Swift side calls `flushMicrotasks()` after invoking it,
    /// then reads `r.done` / `r.isValid` / `r.errors` / `r.diagramType`. The
    /// try/catch is defensive against mermaid builds that throw synchronously
    /// (verified v11.16.0 always returns a Promise, but the catch makes the
    /// wrapper robust to future builds).
    private static let wrapperJS = """
globalThis.__merval = {
  validateMermaid: function(text){
    var r = { done: false, isValid: false, diagramType: null, errors: [] };
    try {
      var firstLine = String(text || '').split(/\\r?\\n/)[0].trim();
      var m = firstLine.match(/^(\\w+)/);
      if (m) r.diagramType = m[1];
      var p = mermaid.parse(text);
      if (p && typeof p.then === 'function') {
        p.then(function(){
          r.done = true; r.isValid = true;
        }).catch(function(e){
          r.done = true; r.isValid = false;
          var msg = (e && e.message) ? e.message : String(e);
          var lineMatch = String(msg).match(/line\\s+(\\d+)/i);
          var line = lineMatch ? parseInt(lineMatch[1], 10) : null;
          r.errors.push({ line: line, code: 'PARSE_ERROR', message: String(msg).split('\\n')[0] });
        });
      } else {
        // Not a Promise (defensive) — treat as success.
        r.done = true; r.isValid = true;
      }
    } catch(e) {
      r.done = true; r.isValid = false;
      var msg = (e && e.message) ? e.message : String(e);
      var lineMatch = String(msg).match(/line\\s+(\\d+)/i);
      var line = lineMatch ? parseInt(lineMatch[1], 10) : null;
      r.errors.push({ line: line, code: 'PARSE_ERROR', message: String(msg).split('\\n')[0] });
    }
    return r;
  }
};
"""
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

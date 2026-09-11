// pattern: Functional Core

import Foundation
import WikiFSTypes

/// App-only identity for one contiguous tool-call run. Derived from the run's
/// first (host) tool-call ID, so a growing live run keeps one stable identity
/// — appending a second call updates the existing group row instead of
/// replacing it. Never an array index; never a raw sentinel string.
struct ChatToolCallGroupID: Hashable, Sendable {
    let hostToolCallID: ToolCallID

    init(hostedBy firstCall: ChatDisplayToolCall) {
        hostToolCallID = firstCall.id
    }

    /// Decoding from the DOM attribute (the host tool-call ID's raw string).
    init(rawValue: String) {
        hostToolCallID = ToolCallID(rawValue: rawValue)
    }

    var rawValue: String { hostToolCallID.rawValue }
}

/// One collapsed tool-call run: the host identity, the run's turn, every
/// original child payload, and the derived aggregate values. Derived values
/// are stored so the row is one Hashable value the render planner can diff.
struct ChatToolCallGroupRow: Hashable, Sendable {
    let id: ChatToolCallGroupID
    let turnID: ChatTurnID
    let calls: [ChatDisplayToolCall]
    let state: ChatToolCallGroupState
    let summary: ChatToolCallGroupSummary
}

/// Closed aggregate lifecycle for one tool-call run. A group is active while
/// any child is pending or running; an active group that already contains
/// failures carries the failure count in its state, so the impossible
/// "running and finished" combination is not representable.
enum ChatToolCallGroupState: Hashable, Sendable {
    case running(failedCount: Int)
    case completed
    case failed(count: Int)

    static func aggregating(_ calls: [ChatDisplayToolCall]) -> ChatToolCallGroupState {
        // Cancelled counts as a failure: the per-row renderer already treats
        // failed and cancelled as the same error surface.
        let failedCount = calls.filter { $0.status == .failed || $0.status == .cancelled }.count
        let isActive = calls.contains { $0.status == .pending || $0.status == .running }
        if isActive {
            return .running(failedCount: failedCount)
        }
        return failedCount == 0 ? .completed : .failed(count: failedCount)
    }

    /// Active while any child is pending or running.
    var isActive: Bool {
        if case .running = self { return true }
        return false
    }

    /// Error surface: any failure or cancellation, including inside an
    /// active group.
    var isError: Bool {
        switch self {
        case .running(let failedCount): failedCount > 0
        case .completed: false
        case .failed: true
        }
    }

    /// Symbol + text state cue. Never color-only (accessibility).
    var symbol: String {
        switch self {
        case .running: "◌"
        case .completed: "✓"
        case .failed: "⚠"
        }
    }

    var text: String {
        switch self {
        case .running(let failedCount):
            failedCount == 0 ? "Running" : "Running, \(failedCount) failed"
        case .completed:
            "Completed"
        case .failed(let count):
            count == 1 ? "1 failed" : "\(count) failed"
        }
    }
}

/// Deterministic, output-blind counts for one tool-call run. Categories come
/// only from normalized, known tool names plus a mechanically decidable
/// single-path grammar over the call's input descriptor — never from tool
/// output, so arbitrary command results cannot change a summary.
struct ChatToolCallGroupSummary: Hashable, Sendable {
    /// Ordered categories for the collapsed phrase. The order is part of the
    /// contract: files edited, edits, commands, files read, reads, searches,
    /// other calls.
    enum Category: Int, CaseIterable, Sendable {
        case editedFiles
        case editOperations
        case shellCommands
        case readFiles
        case readOperations
        case searches
        case otherToolCalls

        var singularLabel: String {
            switch self {
            case .editedFiles: "file edited"
            case .editOperations: "edit"
            case .shellCommands: "command"
            case .readFiles: "file read"
            case .readOperations: "read"
            case .searches: "search"
            case .otherToolCalls: "other call"
            }
        }

        /// Explicit plural forms — the phrase is not a blind `+ "s"` rule
        /// ("files read", "searches").
        var pluralLabel: String {
            switch self {
            case .editedFiles: "files edited"
            case .editOperations: "edits"
            case .shellCommands: "commands"
            case .readFiles: "files read"
            case .readOperations: "reads"
            case .searches: "searches"
            case .otherToolCalls: "other calls"
            }
        }

        func label(forCount count: Int) -> String {
            count == 1 ? singularLabel : pluralLabel
        }
    }

    struct CategoryCount: Hashable, Sendable {
        let category: Category
        let count: Int
    }

    let totalCount: Int
    /// Non-zero counts in ascending `Category` order.
    let counts: [CategoryCount]

    /// "3 commands, 5 files read, and 2 searches" — singular and plural
    /// handled per category; empty only when the group has no calls.
    var phrase: String {
        let parts = counts.map { "\($0.count) \($0.category.label(forCount: $0.count))" }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return parts.joined(separator: " and ")
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }

    /// Classify every call and count. Missing and ambiguous read/edit
    /// descriptors each count as one distinct operation (keyed by call), so a
    /// legacy run is never under-counted. Grammar-approved paths deduplicate
    /// by exact normalized string within their category.
    static func summarizing(_ calls: [ChatDisplayToolCall]) -> ChatToolCallGroupSummary {
        var pathCounts: [Category: Set<String>] = [:]
        var operationCounts: [Category: Int] = [:]
        var total = 0

        for call in calls {
            total += 1
            let normalized = ChatToolCallNameNormalizer.normalizedName(for: call.toolName)
            switch normalized {
            case .shell:
                operationCounts[.shellCommands, default: 0] += 1
            case .search:
                operationCounts[.searches, default: 0] += 1
            case .read, .edit:
                let category: Category = normalized == .read ? .readFiles : .editedFiles
                let operationCategory: Category = normalized == .read ? .readOperations : .editOperations
                if let path = ChatToolCallSinglePathGrammar.singlePath(in: call.detail) {
                    pathCounts[category, default: []].insert(path)
                } else {
                    // Missing or ambiguous descriptor: one distinct operation
                    // per tool call, never merged, never guessed from output.
                    operationCounts[operationCategory, default: 0] += 1
                }
            case .other:
                operationCounts[.otherToolCalls, default: 0] += 1
            }
        }

        let counts = Category.allCases.map { category in
            let pathCount = pathCounts[category]?.count ?? 0
            let operationCount = operationCounts[category] ?? 0
            return CategoryCount(category: category, count: pathCount + operationCount)
        }
        .filter { $0.count > 0 }
        return ChatToolCallGroupSummary(totalCount: total, counts: counts)
    }
}

/// Normalized tool names the classifier recognizes. Both backends' names are
/// covered: the Claude path (`Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`,
/// `WebSearch`) and the ACP kind-derived names (`Bash`, `Read`, `Edit`,
/// `webfetch`, `search`). Names are lowercased with separators removed before
/// comparison; everything unknown or legacy counts as `other`.
enum ChatToolCallNameNormalizer {
    enum NormalizedName {
        case shell
        case read
        case edit
        case search
        case other
    }

    static func normalizedName(for toolName: String) -> NormalizedName {
        let normalized = toolName.lowercased()
            .filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "bash", "execute", "shell", "command":
            return .shell
        case "read":
            return .read
        case "edit", "write":
            return .edit
        case "grep", "glob", "search", "websearch":
            return .search
        default:
            return .other
        }
    }
}

/// The mechanically decidable single-path grammar for read and edit
/// descriptors (plans/chat-tool-call-summary.md §grammar).
///
/// Accepted forms, after quote handling:
/// - `/`-absolute paths (`/tmp/a`)
/// - `~/` paths (`~/notes.md`)
/// - `./` or `../` paths (`./my notes` — spaces allowed in path forms)
/// - relative paths containing at least one `/` (`docs/my notes.md`)
/// - a bare filename whose FINAL extension is in the fixed case-insensitive
///   allowlist (`notes.md`, `a.b.swift`; `archive.tar.gz` fails because `gz`
///   is not listed; `Makefile`, `.env`, `notes.unknown` fail)
///
/// Rejected: control characters and line breaks; `://`; Windows drive or UNC
/// prefixes; backslashes; percent escapes; a leading `-`; a trailing `/`;
/// repeated `//`; colon, semicolon, pipe, ampersand, backtick, dollar, angle
/// brackets, parentheses, braces, brackets, `*`, `?`; newline- or
/// comma-separated locations; unbalanced quotes. `..` is never resolved, `~`
/// never expanded, case never changed, escapes never decoded, and the file
/// system is never consulted.
enum ChatToolCallSinglePathGrammar {
    /// Fixed allowlist of final extensions that make a bare filename a path.
    ///
    /// Deliberately absent: renderer-package diagram extensions. Renderer
    /// source-neutrality contracts keep renderer format names out of
    /// production Swift entirely (even in comments), so files with such
    /// extensions count as ambiguous operations instead.
    static let filenameExtensions: Set<String> = [
        "md", "markdown", "txt", "json", "jsonc", "yaml", "yml", "toml",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "py", "rb",
        "js", "jsx", "ts", "tsx", "css", "html", "xml", "sql", "sh", "zsh",
        "fish", "csv", "tsv", "pdf", "docx", "png", "jpg", "jpeg", "gif",
        "webp", "svg",
    ]

    /// Characters that disqualify a descriptor outright. Quotes are handled
    /// by the balanced-pair rule below, not this set.
    static let rejectedCharacters: Set<Character> = [
        ":", ";", "|", "&", "`", "$", "<", ">", "(", ")", "{", "}", "[", "]",
        "*", "?", "%", ",", "\\",
    ]

    /// Parse `descriptor` into one normalized path, or nil when it is
    /// missing, ambiguous, or rejected. PURE — no file system access.
    static func singlePath(in descriptor: String?) -> String? {
        guard var candidate = descriptor else { return nil }

        // 1. Trim Unicode whitespace outside the descriptor.
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Remove exactly one balanced pair of matching ASCII quotes, then
        //    trim whitespace once more inside those quotes.
        if candidate.count >= 2,
           let first = candidate.first,
           first == "'" || first == "\"",
           candidate.last == first {
            candidate = String(candidate.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. An empty result is ambiguous.
        guard candidate.isEmpty == false else { return nil }

        // 4. Any surviving quote is unbalanced — reject.
        if candidate.contains("'") || candidate.contains("\"") { return nil }

        // 5. Control characters (C0 + DEL) reject line breaks, separators,
        //    and non-printables in one rule.
        if candidate.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return nil
        }

        // 6. Structural rejections: URLs, Windows drive letters and UNC
        //    paths (colon / backslash / repeated slash), escapes, glob and
        //    shell metacharacters, and multi-location lists.
        if candidate.contains("://") { return nil }
        if candidate.contains("//") { return nil }
        if let first = candidate.first, rejectedCharacters.contains(first) || first == "-" {
            return nil
        }
        for character in candidate where rejectedCharacters.contains(character) {
            return nil
        }
        if candidate.hasSuffix("/") { return nil }

        // 7. Accept unambiguous path forms verbatim (normalized only).
        if candidate.hasPrefix("/")
            || candidate.hasPrefix("~/")
            || candidate.hasPrefix("./")
            || candidate.hasPrefix("../")
            || candidate.contains("/")
        {
            return normalized(candidate)
        }

        // 8. Bare filename: the final extension must be allowlisted. Dotfiles
        //    (`​.env`), extensionless names (`Makefile`), and unknown
        //    extensions stay ambiguous operations.
        guard let lastDot = candidate.lastIndex(of: "."),
              candidate[candidate.index(after: lastDot)...].isEmpty == false
        else { return nil }
        let finalExtension = candidate[candidate.index(after: lastDot)...].lowercased()
        guard filenameExtensions.contains(finalExtension) else { return nil }
        return normalized(candidate)
    }

    /// Canonical form of an accepted path: internal `/./` components collapse
    /// to `/` and a trailing `/.` is removed. Nothing else changes.
    static func normalized(_ path: String) -> String {
        var result = path
        while result.contains("/./") {
            result = result.replacingOccurrences(of: "/./", with: "/")
        }
        if result.hasSuffix("/.") {
            result = String(result.dropLast(2))
        }
        return result
    }
}

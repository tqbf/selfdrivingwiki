import Foundation
import WikiFSTypes

/// Send seam for safe extractor diagnostics. Production writes one formatted
/// line per event to `DebugLog.extraction`; tests capture lines in memory.
/// Every line is produced by `ManagedExtractorDiagnostics`, which bounds
/// length, collapses to one line, strips control characters, and redacts the
/// home directory prefix before the sink sees it.
public protocol ExtractorDiagnosticsSink: Sendable {
    func send(_ line: String)
}

/// Production sink. Console.app reads it under the extraction category of
/// the debug subsystem.
public struct DebugLogExtractorDiagnosticsSink: ExtractorDiagnosticsSink {
    public init() {}

    public func send(_ line: String) {
        DebugLog.extraction(line)
    }
}

/// Pure formatting for managed extractor diagnostics. No function here reads
/// the environment, spawns a process, or logs on its own, so redaction and
/// bounds are unit-testable in isolation.
public enum ManagedExtractorDiagnostics {
    /// One safe diagnostic event. The associated strings must already be
    /// safe (command names, categories, redacted paths, bounded tails).
    public enum Event: Sendable, Equatable {
        /// One runtime executable was selected and pinned (plan step 26).
        case runtimeResolved(
            command: String, source: String, path: String, identity: String)
        /// Runtime resolution failed at a typed stage (plan step 27).
        case runtimeResolutionFailed(command: String, category: String, detail: String)
        /// The pinned executable identity changed between resolution and
        /// spawn; no child started.
        case executableChanged(command: String, identity: String)
        /// The spawn itself failed.
        case spawnFailure(command: String, detail: String)
        /// The extractor exited nonzero; the stderr tail is bounded and
        /// one-line.
        case nonzeroExit(command: String, termination: String, stderrTail: String)
        /// The extractor's stdout violated the protocol.
        case protocolFailure(command: String, detail: String)

        /// The one-line Console form. The prefix names the category so every
        /// failure stage is distinguishable in the log (AC.7). Every
        /// payload is sanitized here, at the event boundary: control
        /// characters and line breaks can never enter a Console line even
        /// when a caller passes raw subprocess output.
        public var consoleLine: String {
            func safe(_ text: String) -> String {
                ManagedExtractorDiagnostics.sanitize(
                    text,
                    limit: ManagedExtractorDiagnostics.maximumDetailLength)
            }
            switch self {
            case let .runtimeResolved(command, source, path, identity):
                return "runtime resolved: command=\(safe(command)) source=\(safe(source)) path=\(safe(path)) identity=\(safe(identity))"
            case let .runtimeResolutionFailed(command, category, detail):
                return "runtime resolution failed: command=\(safe(command)) category=\(safe(category)) detail=\(safe(detail))"
            case let .executableChanged(command, identity):
                return "executable changed before spawn: command=\(safe(command)) identity=\(safe(identity))"
            case let .spawnFailure(command, detail):
                return "spawn failure: command=\(safe(command)) detail=\(safe(detail))"
            case let .nonzeroExit(command, termination, stderrTail):
                let tail = stderrTail.isEmpty ? "<empty>" : stderrTail
                return "nonzero extractor exit: command=\(safe(command)) termination=\(safe(termination)) stderr=\(safe(tail))"
            case let .protocolFailure(command, detail):
                return "protocol failure: command=\(safe(command)) detail=\(safe(detail))"
            }
        }
    }

    /// Maximum length of any path description that reaches diagnostics.
    public static let maximumPathDescriptionLength = 160
    /// Maximum length of any diagnostic detail text.
    public static let maximumDetailLength = 200
    /// Maximum length of a normalized stderr tail for display.
    public static let maximumStderrTailDisplayLength = 512

    /// Collapses `text` to one line, strips control characters, and caps the
    /// length. Line breaks become spaces, so a multi-line payload cannot fake
    /// a second log line or smuggle a newline past a bounds check.
    public static func sanitize(_ text: String, limit: Int) -> String {
        var sanitized = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            // Control characters (including line breaks and tabs) become one
            // space each; no raw control byte can reach the log line.
            if scalar.value < 0x20 || scalar.value == 0x7F {
                sanitized.append(" ")
            } else {
                sanitized.append(scalar)
            }
        }
        var collapsed = String(sanitized)
        while collapsed.contains("  ") {
            collapsed = collapsed.replacingOccurrences(of: "  ", with: " ")
        }
        collapsed = collapsed.trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(limit))
    }

    /// A home-redacted, bounded path description. The user's home directory
    /// prefix becomes `~`; everything else stays lexical. The full path never
    /// reaches diagnostics when it starts with the home directory.
    public static func redactedPath(
        for url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let homePath = home.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        let described: String
        if urlPath == homePath {
            described = "~"
        } else if urlPath.hasPrefix(homePath + "/") {
            described = "~" + urlPath.dropFirst(homePath.count)
        } else {
            described = urlPath
        }
        return sanitize(described, limit: maximumPathDescriptionLength)
    }

    /// A short stable fingerprint of a path, for correlating log lines
    /// without repeating even the redacted path.
    public static func pathFingerprint(for url: URL) -> String {
        let digest = ExtractorSHA256.digest(Data(url.standardizedFileURL.path.utf8))
        return String(digest.hex.prefix(8))
    }

    /// A short stable description of a pinned executable identity.
    public static func identityFingerprint(
        for identity: RuntimeExecutableIdentity
    ) -> String {
        "dev:\(identity.device)-ino:\(identity.inode)"
    }

    /// A bounded, one-line stderr tail: the final lines of `data`, joined
    /// with " | ", capped at `displayLimit`, with control characters and
    /// line breaks removed.
    public static func singleLineTail(_ data: Data, displayLimit: Int) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let tail = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(3)
            .joined(separator: " | ")
        return sanitize(String(tail), limit: displayLimit)
    }
}

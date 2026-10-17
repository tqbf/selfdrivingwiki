// pattern: Functional Core

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Synchronous diagnostic rendering for a failed subprocess spawn.
///
/// When a child fails to start, Foundation throws an `NSError` whose payload
/// carries the OS status — the error domain, the errno, and sometimes the path
/// that could not be spawned. That payload is the only denial context available
/// at spawn time: Seatbelt denial records reach the unified log asynchronously
/// (issue #1279), so nothing synchronous can quote them. `error.localizedDescription`
/// flattens this payload — a non-localized error renders as a generic sentence,
/// and an `NSError` loses its numeric status and failing path (issue #1409).
///
/// `render` keeps what the error itself carries, so a surfaced failure reads
/// `spawn /usr/bin/sandbox-exec: Operation not permitted (POSIX errno 1)`
/// instead of a bare "failed to launch".
public enum SpawnFailureDetail {

    /// Upper bound for rendered cause text. Mirrors the transcript-cause bound
    /// in `WikiFSEngine.ACPToolFailureClassification`: a pathological deeply
    /// nested error chain must not bloat a user-visible error, while signature
    /// lines — which lead the text — survive.
    public static let maxTextLength = 2_048

    /// The POSIX errno when `error` carries one (`NSPOSIXErrorDomain`), else nil.
    public static func posixErrno(of error: Error) -> Int32? {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return nil }
        return Int32(truncatingIfNeeded: nsError.code)
    }

    /// `EPERM` (operation not permitted) — the errno macOS reports when it
    /// denies a spawn, including a `sandbox_apply` Seatbelt denial at launch.
    public static let eperm: Int32 = EPERM

    /// Render `error` with its synchronously available OS status, prefixed with
    /// the failing operation when one is given.
    ///
    /// - POSIX errors render as `<phrase> (POSIX errno N)`, plus the failing
    ///   file path when the error carries one.
    /// - Other `NSError`s keep their domain and code so a search can map the
    ///   status back to its origin.
    /// - Non-`NSError` Swift errors render via `String(describing:)` — their
    ///   case payload is the diagnostics; `localizedDescription` would drop it.
    /// - An `NSUnderlyingError` is rendered recursively (one level).
    /// - A `LocalizedError` description leads the text when one exists, with
    ///   the structural rendering appended when it adds payload.
    public static func render(_ error: Error, operation: String? = nil) -> String {
        let body = renderBody(error)
        guard let operation, !operation.isEmpty else { return bounded(body) }
        return bounded("\(operation): \(body)")
    }

    /// True when `error` is a POSIX error carrying exactly this errno.
    public static func isPosixError(_ error: Error, code: Int32) -> Bool {
        posixErrno(of: error) == code
    }

    // MARK: - Private

    private static func renderBody(_ error: Error) -> String {
        let nsError = error as NSError
        let structural: String
        switch nsError.domain {
        case NSPOSIXErrorDomain, NSMachErrorDomain, NSCocoaErrorDomain:
            // Foundation-produced error: the structured status is the payload.
            var parts: [String] = [statusText(of: nsError)]
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                parts.append("underlying: \(renderBody(underlying))")
            }
            structural = parts.joined(separator: "; ")
        default:
            // Any Swift error bridges to an NSError with a generated domain,
            // so domain membership — not castability — is the test. A bridged
            // error's payload lives in its case structure: `localizedDescription`
            // would collapse it to Foundation's generic sentence (#1409).
            // An unknown-domain NSError still renders its status here via
            // `String(describing:)`.
            structural = String(describing: error)
        }
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty,
           description != structural {
            return "\(description) [\(structural)]"
        }
        return structural
    }

    private static func statusText(of nsError: NSError) -> String {
        switch nsError.domain {
        case NSPOSIXErrorDomain:
            var text = "\(phrase(of: nsError)) (POSIX errno \(nsError.code))"
            if let path = nsError.userInfo[NSFilePathErrorKey] as? String {
                text += " file: \(path)"
            }
            return text
        case NSMachErrorDomain:
            return "\(phrase(of: nsError)) (Mach error \(nsError.code))"
        default:
            return "\(phrase(of: nsError)) (domain \(nsError.domain), code \(nsError.code))"
        }
    }

    private static func phrase(of nsError: NSError) -> String {
        let description = nsError.localizedDescription
        // A bare Foundation boilerplate phrase adds nothing over the status;
        // fall back to the structural description when it is all there is.
        if description.isEmpty {
            return String(describing: nsError)
        }
        return description
    }

    private static func bounded(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        return String(text.prefix(maxTextLength))
            + "\n[truncated at \(maxTextLength) characters]"
    }
}

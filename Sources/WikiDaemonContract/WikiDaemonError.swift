#if os(macOS)
import Foundation

/// Errors surfaced by the daemon XPC transport (the typed client wrappers in
/// `WikiCtlCore` throw these when a connection can't be established or the
/// daemon returns a malformed reply). Part of the app↔daemon **contract**, so
/// both sides share the same error vocabulary.
public enum WikiDaemonError: Error, LocalizedError {
    case connectionFailed
    case unexpectedReply

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Could not connect to the wikid daemon. Is it running? (make install-daemon)"
        case .unexpectedReply:
            return "The wikid daemon returned an unexpected reply."
        }
    }
}
#endif

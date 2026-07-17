import Foundation
import WikiFSEngine

/// The trailing status a source row shows, mirroring the two phases in
/// `AgentLauncher`. Pure data (no SwiftUI) so the precedence — extraction phase
/// beats agent phase beats the ready/ingested idle glyphs — is unit-testable
/// without driving launcher or view state.
public enum SourceRowStatus: Equatable, Sendable {
    /// pdf2md conversion in flight (extraction phase).
    case extracting
    /// Agent run committed for this source (agent phase).
    case ingesting
    /// Already ingested, idle.
    case ingested
    /// Not yet ingested, idle.
    case ready

    /// Pure precedence predicate: extraction phase beats agent phase beats the
    /// idle glyphs. Mirrors the two-flag split — a pure extraction never shows
    /// "Ingesting…" and vice versa.
    public static func status(
        isExtracting: Bool, isIngesting: Bool, hasBeenIngested: Bool
    ) -> SourceRowStatus {
        if isExtracting { return .extracting }
        if isIngesting { return .ingesting }
        return hasBeenIngested ? .ingested : .ready
    }
}

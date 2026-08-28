import Foundation
import WikiFSCore

/// Abstraction over the File Provider's change-signaling and mount-path surface.
///
/// The engine (`AgentOperationRunner`, `AgentLauncher`) uses this to signal FP
/// changes and read the mount path without depending on the AppKit-coupled
/// `FileProviderFacade` (which stays in the app target). The app conforms
/// `FileProviderFacade` to this protocol at wiring time.
///
/// See `plans/multi-wiki-daemon.md` §3.2 (the `ChangeSignaler` protocol seam).
@MainActor
public protocol ChangeSignaler: AnyObject {
    /// Signal the File Provider that content changed (debounced).
    func signalChange() async

    /// The mount path for the active wiki's File Provider domain, if mounted.
    var path: String? { get }
}

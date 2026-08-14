import Foundation

/// Failures from resolving the per-developer identifiers in ``WikiIdentifiers``.
///
/// Conforms to `CustomStringConvertible` as well as `LocalizedError` because the
/// CLI and the daemon report failures with `"\(error)"`, which uses
/// `String(describing:)` and would otherwise print the raw enum case
/// (`unconfiguredAppGroupID(fallback: "…")`). The whole point of this error is
/// the instructions it carries, so both spellings must produce them.
public enum WikiIdentifiersError: Error, LocalizedError, CustomStringConvertible, Equatable {

    /// No configuration source stated an App Group id, so the compiled-in
    /// fallback is all that is left. Raised by
    /// ``DatabaseLocation/appGroupContainerDirectory()`` instead of creating a
    /// container under an id nobody chose.
    case unconfiguredAppGroupID(fallback: String)

    public var errorDescription: String? {
        switch self {
        case .unconfiguredAppGroupID(let fallback):
            """
            Cannot determine the App Group id, so there is no safe container to \
            open.

            Nothing set it: no WIKI_APP_GROUP_ID in the environment, no \
            WIKIAppGroupID key in the Info.plist, no wiki-identifiers.env \
            sidecar next to the executable, and no signing/local.config in any \
            parent directory.

            The build would otherwise fall back to "\(fallback)", which is the \
            upstream author's registered App Group, not this installation's. \
            Using it reads an empty registry and writes config to the wrong \
            container.

            Fix it in one of these ways:
              - Run signing/setup.sh to provision your own ids and write \
            signing/local.config.
              - Launch the binary from inside the built .app, so it finds the \
            wiki-identifiers.env sidecar.
              - Export WIKI_APP_GROUP_ID=<your group id> for a one-off run.
            """
        }
    }

    public var description: String { errorDescription ?? "\(self)" }
}

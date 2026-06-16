import Foundation

/// The pure decision logic behind robust File Provider domain registration
/// (`plans/llm-wiki.md` Phase D gate finding — a freshly-created wiki's domain
/// could fail to register *silently* under a busy/churned `fileproviderd`, so a
/// single `add(domain)` is not enough: we must VERIFY the domain actually landed
/// and RETRY a bounded number of times before giving up).
///
/// PURE + injectable, mirroring `PathPreflight`: the app layer
/// (`FileProviderSpike`) owns the side effects (`NSFileProviderManager.add`,
/// `.domains()`, `signalEnumerator`, the async backoff sleep); THIS type owns
/// only the "is it registered? / should we retry? / have we exhausted our
/// attempts?" arithmetic, so that logic is unit-tested without importing
/// `FileProvider`.
public enum DomainRegistrationPolicy {
    /// How many `add(domain)`-then-verify rounds to attempt before giving up.
    /// Small and bounded: a healthy daemon registers on attempt 1; a transiently
    /// busy one usually recovers within a couple of retries; a truly wedged one
    /// won't recover no matter how long we spin (see `ISSUES.md` churned-domain
    /// finding), so spinning forever only hides the failure.
    public static let maxAttempts = 3

    /// Backoff before re-attempting `add` after a failed verify. Short — the
    /// window we're covering is the daemon being momentarily busy, not down.
    public static let retryBackoff: Duration = .milliseconds(600)

    /// What the caller should do after one `add`+verify round, given whether the
    /// domain is now present in `NSFileProviderManager.domains()` and how many
    /// attempts have been spent so far.
    public enum Decision: Equatable, Sendable {
        /// The domain is registered (verified present). Stop; nudge enumeration.
        case registered
        /// Not yet present, but attempts remain. Back off, then `add` again.
        case retry
        /// Not present and attempts are exhausted. Surface a loud failure.
        case failed
    }

    /// Decide the next step after an `add`+verify round.
    ///
    /// - Parameters:
    ///   - domainPresent: Did `<wikiID>` appear in the daemon's domain list this
    ///     round? (Computed by the caller via `isRegistered(domainIDs:wikiID:)`.)
    ///   - attemptsMade: How many `add`+verify rounds have completed, INCLUDING
    ///     this one (so the first round passes `1`).
    /// - Returns: `.registered` if present; otherwise `.retry` while
    ///   `attemptsMade < maxAttempts`, else `.failed`.
    public static func decide(domainPresent: Bool, attemptsMade: Int) -> Decision {
        if domainPresent {
            return .registered
        }
        return attemptsMade < maxAttempts ? .retry : .failed
    }

    /// Whether `wikiID` is present in a daemon-reported list of domain
    /// identifiers. Factored out so the caller's `domains()` → identifier mapping
    /// has one tested home (an exact match on the raw ULID identifier).
    public static func isRegistered(domainIDs: [String], wikiID: String) -> Bool {
        domainIDs.contains(wikiID)
    }
}

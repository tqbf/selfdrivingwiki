import Foundation

/// Why a File Provider domain is being torn down.
///
/// `remove(domain)` is the single destructive operation in the domain lifecycle:
/// it deletes the daemon's on-disk replica, not just the registration. Issue #919
/// was a rename quietly doing exactly that under a doc comment calling it
/// "cosmetic", so the reason is a REQUIRED parameter rather than a log string —
/// every teardown has to name itself at the call site, and a test can assert that
/// an operation performed no removal at all (and say which illegitimate one it
/// found when it fails).
///
/// There are exactly three legitimate reasons. A rename is not among them.
public enum DomainRemovalReason: String, Equatable, Sendable, CaseIterable {
    /// The user deleted the wiki. The replica should go with it.
    case wikiDeleted
    /// The container hierarchy changed (`DomainRegistrationPolicy` schema bump),
    /// so the daemon's cache must be rebuilt from scratch.
    case schemaMigration
    /// The `WIKIFS_REENUMERATE=1` developer hatch, forcing a clean re-enumeration.
    case reenumerateHatch
}

/// One registered File Provider domain as the daemon reports it.
///
/// Carries the `displayName` alongside the identifier deliberately. The previous
/// listing mapped `\.identifier.rawValue` and discarded the name, which meant
/// domain presence was observable but the *display name* was not — so nothing
/// could verify that a rename had actually taken effect, only that the domain
/// still existed. That gap is why #919's in-place `add` upsert needs a
/// post-condition check rather than trust in the SDK doc comment.
public struct RegisteredDomain: Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// The three daemon calls that make up the domain lifecycle, behind a protocol so
/// the decisions around them can be tested without a live `fileproviderd`.
///
/// Scope is deliberately narrow: registration lifecycle only. Item-level
/// resolution (`NSFileProviderManager(for:)` → `getUserVisibleURL` /
/// `signalEnumerator`) stays on the concrete API — it's a much wider surface and
/// it isn't where the lifecycle bugs have been.
public protocol FileProviderDomainService: Sendable {
    /// Register a domain, or update an existing one's display name in place.
    ///
    /// This is an upsert keyed by identifier: "If a domain with the same
    /// identifier already exists, `addDomain` will update the display name and
    /// hidden state of the domain and succeed" (`NSFileProviderManager.h`).
    func add(id: String, displayName: String) async throws

    /// Tear down a domain AND its on-disk replica. Destructive — see
    /// ``DomainRemovalReason``.
    func remove(id: String, reason: DomainRemovalReason) async throws

    /// The daemon's current domain list. Returns `[]` if the list can't be
    /// fetched, so callers read a failure as "not present" and keep retrying.
    func domains() async -> [RegisteredDomain]
}

extension FileProviderDomainService {
    /// The display name the daemon currently reports for `id`, or `nil` if the
    /// domain isn't registered. Used to verify an in-place rename landed.
    public func displayName(for id: String) async -> String? {
        await domains().first { $0.id == id }?.displayName
    }
}

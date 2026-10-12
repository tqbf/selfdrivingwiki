import Foundation

/// One completed adapter adoption — the rollback record behind the
/// one-click **Restore previous command** action (AC 3). Stores BOTH the
/// typed specs (semantics, display) and the exact previous argv (byte-exact
/// restore — the previous command may predate the canonical parse shapes).
public struct AdapterAdoptionRecord: Codable, Hashable, Sendable {
    /// When the adoption committed.
    public let adoptedAt: Date
    /// The exact argv the provider ran before the adoption.
    public let fromCommand: [String]
    /// The typed shape of the from command. `nil` only for a from-command
    /// that predates the parser — adoption never writes such a record, but
    /// decode stays permissive.
    public let fromSpec: ACPParsedPackageCommand?
    /// The adopted exact pin.
    public let toSpec: ACPPackageSpec

    public init(
        adoptedAt: Date,
        fromCommand: [String],
        fromSpec: ACPParsedPackageCommand?,
        toSpec: ACPPackageSpec
    ) {
        self.adoptedAt = adoptedAt
        self.fromCommand = fromCommand
        self.fromSpec = fromSpec
        self.toSpec = toSpec
    }
}

/// Who owns a provider's launch command. The manager may only rewrite a
/// command it can vouch for (MUST: package recognition is not ownership —
/// a user-customized npx/bun/uvx command is never auto-adopted).
public enum AdapterOwnership: Codable, Hashable, Sendable {
    /// The manager wrote (or froze at add) this exact argv. An adoption may
    /// commit only while the live command still equals the baseline.
    case managed(baseline: [String])
    /// The user edited the command after the add. The manager skips the
    /// provider entirely.
    case userOwned

    /// The exact argv this ownership state pins, when any.
    public var baseline: [String]? {
        guard case .managed(let baseline) = self else { return nil }
        return baseline
    }
}

/// A recorded probe failure with its bounded backoff window. A broken
/// upstream release must not turn into a probe loop: each failure pushes
/// `backoffUntil` further out, capped by the owner's policy.
public struct AdapterProbeFailure: Codable, Hashable, Sendable {
    /// Consecutive probe failures for the same candidate lineage.
    public var count: Int
    /// The last failure's diagnostic (error description only — never stderr
    /// secrets; probe errors carry no credential material).
    public var lastError: String
    public var lastFailedAt: Date
    /// Automatic checks skip this provider until this date. Manual checks
    /// bypass it (an explicit user action).
    public var backoffUntil: Date

    public init(count: Int, lastError: String, lastFailedAt: Date, backoffUntil: Date) {
        self.count = count
        self.lastError = lastError
        self.lastFailedAt = lastFailedAt
        self.backoffUntil = backoffUntil
    }
}

/// Everything the adapter upgrade manager persists about one provider.
/// All fields optional: a provider with no state decodes to this struct with
/// every field nil (forward-compatible with pre-upgrade-manager files).
public struct AdapterUpgradeState: Codable, Hashable, Sendable {
    /// The last check's conclusion for this provider.
    public var finding: ACPAdapterUpgradeDecision?
    /// When the manager last evaluated this provider.
    public var checkedAt: Date?
    /// The last committed adoption (the rollback source).
    public var lastAdoption: AdapterAdoptionRecord?
    /// The recorded probe failure + backoff, when the last probe failed.
    public var probeFailure: AdapterProbeFailure?
    /// A candidate version the user rolled back. The automatic loop must not
    /// re-adopt this exact version until a strictly newer candidate appears
    /// or the user explicitly retries (a manual check).
    public var suppressedCandidateVersion: ACPAgentVersion?
    /// Who owns the current command (drives adoption eligibility).
    public var ownership: AdapterOwnership?

    public init(
        finding: ACPAdapterUpgradeDecision? = nil,
        checkedAt: Date? = nil,
        lastAdoption: AdapterAdoptionRecord? = nil,
        probeFailure: AdapterProbeFailure? = nil,
        suppressedCandidateVersion: ACPAgentVersion? = nil,
        ownership: AdapterOwnership? = nil
    ) {
        self.finding = finding
        self.checkedAt = checkedAt
        self.lastAdoption = lastAdoption
        self.probeFailure = probeFailure
        self.suppressedCandidateVersion = suppressedCandidateVersion
        self.ownership = ownership
    }

    /// Whether the exact candidate is blocked by a restore suppression.
    public func isSuppressed(candidateVersion: ACPAgentVersion) -> Bool {
        suppressedCandidateVersion == candidateVersion
    }
}

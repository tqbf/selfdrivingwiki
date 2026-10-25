import Foundation
import WikiFSCore
import WikiFSTypes

/// The configuration a breaker state belongs to: this build's lint pipeline
/// (the shipped manifest's pipeline block, hashed) plus the provider, model,
/// and effort the gate matched.
///
/// The state FILE is named by provider/model/effort only. The pipeline digest
/// lives inside the file, so a pipeline change (an app update) finds the old
/// file, sees a different digest, and discards it — the breaker resets in
/// place instead of leaving stale files behind.
public struct LintRepairBreakerKey: Hashable, Sendable {
    public let pipelineDigest: String
    public let provider: String
    public let model: String
    public let effort: String

    public init(pipelineDigest: String, provider: String, model: String, effort: String) {
        self.pipelineDigest = pipelineDigest
        self.provider = provider
        self.model = model
        self.effort = effort
    }

    public init(pipeline: LintAcceptanceManifest.Pipeline, provider: String, model: String, effort: String) {
        self.init(
            pipelineDigest: Self.digest(of: pipeline),
            provider: provider, model: model, effort: effort)
    }

    /// The SHA-256 hex of the pipeline block's canonical form (sorted labels).
    public static func digest(of pipeline: LintAcceptanceManifest.Pipeline) -> String {
        let canonical = [
            "detector=\(pipeline.detectorRevision)",
            "fixtures=\(pipeline.fixtureDigest)",
            "prompt=\(pipeline.promptSHA256)",
        ].joined(separator: "\n")
        return RendererSHA256.digest(Data(canonical.utf8)).hex
    }

    /// Longest sanitized component kept in the readable part of a file name.
    static let maxFileNameComponentLength = 40
    /// Hex characters of the identity hash appended to the file name. The
    /// hash keeps two configurations distinct even when sanitizing makes
    /// their readable parts equal.
    static let fileNameHashLength = 16

    /// A deterministic, filesystem-safe state file name for this
    /// provider/model/effort.
    public var stateFileName: String {
        func sanitized(_ component: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
            let mapped = component.unicodeScalars.map { scalar -> Character in
                scalar.isASCII && allowed.contains(scalar) ? Character(scalar) : "_"
            }
            return String(String(mapped).prefix(Self.maxFileNameComponentLength))
        }
        // U+001F (unit separator) cannot appear in a configured name, so the
        // joined identity is unambiguous.
        let identity = [provider, model, effort].joined(separator: "\u{1F}")
        let hash = RendererSHA256.digest(Data(identity.utf8)).hex.prefix(Self.fileNameHashLength)
        return "\(sanitized(provider))_\(sanitized(model))_\(sanitized(effort))-\(hash).json"
    }
}

/// One recorded repair-run outcome kind.
public enum LintRepairOutcomeKind: String, Codable, Sendable, CaseIterable {
    /// Post-write verification failed on the run's written head.
    case verificationFailure
    /// The user undid a lint run's fixes.
    case userUndo
    /// The user rejected a staged proposal (tier 2) — the hunks were held
    /// for review and the human said no.
    case userRejected
    /// The run's write verified.
    case clean
}

/// What the breaker says about a configuration.
public enum LintBreakerVerdict: Equatable, Sendable {
    case clean
    case tripped(reason: String)
}

/// The local circuit breaker for on-by-default lint repairs. LOCAL STATE CAN
/// ONLY REDUCE AUTHORITY: the breaker can demote a shipped approval to
/// report-only, but nothing it reads can authorize a repair. A missing App
/// Group, an unreadable file, or a forged file all demote.
///
/// State lives in the App Group container under `lint-breaker/`, one
/// versioned JSON file per provider/model/effort (see
/// `LintRepairBreakerKey`). Only the trusted host coordinator records or
/// consults it — never the sandboxed child, which is kernel-denied the App
/// Group anyway.
///
/// Concurrency: a lock-protected final class, because the coordinator
/// paths that call it are synchronous (`AgentOperationRunner` accounting runs
/// on the main actor; the daemon hops there too). The lock serializes
/// read-modify-write within one process; each write is atomic on disk, so a
/// second process (app and daemon) can lose an update but never read a torn
/// file.
// swiftlint:disable:next unchecked_sendable
public final class LintRepairBreaker: @unchecked Sendable {

    // MARK: - Tuning

    /// How many recent repair-run outcomes the window keeps per
    /// configuration. Ten runs is long enough to see a pattern and short
    /// enough that old history does not decide today's authority.
    public static let windowSize = 10
    /// Verification failures within the window that trip the breaker. Two,
    /// because one failure can be a one-off; a second means the
    /// configuration is not reliable on this machine.
    public static let verificationFailureTripCount = 2
    /// User undos within the window that trip the breaker. Two, for the same
    /// reason: one undo can be taste; two mean the repairs are unwanted.
    public static let userUndoTripCount = 2
    /// User rejections of staged proposals within the window that trip the
    /// breaker — same thresholds as undos: repeated rejections mean this
    /// configuration's staged fixes are unwanted.
    public static let userRejectedTripCount = 2

    /// The state file schema this build reads and writes. Any other value is
    /// unreadable state (and therefore tripped).
    static let stateSchema = 1
    /// The App Group subdirectory holding the state files.
    public static let directoryName = "lint-breaker"

    // MARK: - State

    struct Outcome: Codable, Equatable {
        let at: Date
        let kind: LintRepairOutcomeKind
    }

    struct Trip: Codable, Equatable {
        let trippedAt: Date
        let reason: String
    }

    struct State: Codable, Equatable {
        let schema: Int
        let pipelineDigest: String
        let provider: String
        let model: String
        let effort: String
        var outcomes: [Outcome]
        var trip: Trip?
    }

    private enum Loaded {
        case missing
        case loaded(State)
        case unreadable(reason: String)
    }

    private let lock = NSLock()
    private let containerResolver: @Sendable () throws -> URL
    private let now: @Sendable () -> Date

    /// A breaker over the container `containerResolver` returns. The
    /// resolver runs on every call, so a container that cannot be resolved
    /// demotes the call rather than failing construction.
    public init(
        containerResolver: @escaping @Sendable () throws -> URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerResolver = containerResolver
        self.now = now
    }

    /// The production breaker over the resolved App Group container.
    public static func production() -> LintRepairBreaker {
        LintRepairBreaker(containerResolver: { try DatabaseLocation.appGroupContainerDirectory() })
    }

    // MARK: - Consult

    /// The breaker's verdict for one configuration. A pipeline change
    /// discards the old state and answers clean.
    public func consult(_ key: LintRepairBreakerKey) -> LintBreakerVerdict {
        lock.lock()
        defer { lock.unlock() }
        let url: URL
        switch stateFileURL(for: key) {
        case .failure(let unavailable):
            return .tripped(reason: unavailable.reason)
        case .success(let resolved):
            url = resolved
        }
        switch load(url) {
        case .missing:
            return .clean
        case .unreadable(let reason):
            DebugLog.agent("lint breaker: \(reason) at \(url.path) — demoting")
            return .tripped(reason: "breaker state unreadable")
        case .loaded(let state):
            if state.pipelineDigest != key.pipelineDigest {
                discard(url)
                return .clean
            }
            if let trip = state.trip {
                return .tripped(reason: trip.reason)
            }
            return .clean
        }
    }

    /// The authority a gate selection earns after the breaker has its say
    /// (the engine calls this AFTER a `LintCoordinatorGate` match).
    /// `.reportOnly` passes through; `.repairAuthorized` survives only on a
    /// clean breaker; a `.stagedProposal` selection survives as tier 2 on a
    /// clean breaker and degrades to report-only when tripped (proposals
    /// pause for that configuration). `key == nil` (this build could not
    /// name its own configuration) demotes both.
    public func authority(
        after selection: LintRolloutSelection,
        key: LintRepairBreakerKey?
    ) -> LintRepairAuthority {
        switch selection {
        case .reportOnly(let reason):
            return .reportOnly(reason: reason)
        case .repairAuthorized(let approvalID):
            let approved = LintRepairAuthority.shippedApproval(LintApprovalID(rawValue: approvalID))
            guard let key else {
                return approved.demoted(
                    to: .breakerDemoted,
                    reason: "circuit breaker tripped: breaker configuration unavailable")
            }
            switch consult(key) {
            case .clean:
                return approved
            case .tripped(let reason):
                return approved.demoted(to: .breakerDemoted, reason: "circuit breaker tripped: \(reason)")
            }
        case .stagedProposal(let reason):
            let proposed = LintRepairAuthority.stagedProposal(reason: reason)
            guard let key else {
                return proposed.demoted(
                    to: .reportOnly,
                    reason: "breaker configuration unavailable — proposals paused for this configuration")
            }
            switch consult(key) {
            case .clean:
                return proposed
            case .tripped(let tripReason):
                return proposed.demoted(
                    to: .reportOnly,
                    reason: "proposals paused for this configuration — circuit breaker tripped: \(tripReason)")
            }
        }
    }

    /// What the breaker's window holds for one configuration right now: the
    /// outcome counts the trip rules count, and whether the breaker is
    /// currently tripped. Read-only — the Undo UI's "N of 2 allowed … used"
    /// context line renders this; consulting it never mutates state.
    public struct WindowStatus: Equatable, Sendable {
        public let windowSize: Int
        public let verificationFailures: Int
        public let userUndos: Int
        public let userRejections: Int
        public let tripReason: String?

        public var isTripped: Bool { tripReason != nil }

        public init(
            windowSize: Int, verificationFailures: Int, userUndos: Int,
            userRejections: Int = 0, tripReason: String?
        ) {
            self.windowSize = windowSize
            self.verificationFailures = verificationFailures
            self.userUndos = userUndos
            self.userRejections = userRejections
            self.tripReason = tripReason
        }
    }

    /// The window status for one configuration. A pipeline change discards
    /// the old state and answers an empty, clean window; unreadable state
    /// answers a tripped window (the same demotion `consult` applies).
    public func windowStatus(for key: LintRepairBreakerKey) -> WindowStatus {
        lock.lock()
        defer { lock.unlock() }
        let url: URL
        switch stateFileURL(for: key) {
        case .failure(let unavailable):
            return WindowStatus(
                windowSize: Self.windowSize, verificationFailures: 0, userUndos: 0,
                tripReason: unavailable.reason)
        case .success(let resolved):
            url = resolved
        }
        switch load(url) {
        case .missing:
            return WindowStatus(
                windowSize: Self.windowSize, verificationFailures: 0, userUndos: 0,
                tripReason: nil)
        case .unreadable(let reason):
            DebugLog.agent("lint breaker: \(reason) at \(url.path) — demoting")
            return WindowStatus(
                windowSize: Self.windowSize, verificationFailures: 0, userUndos: 0,
                tripReason: "breaker state unreadable")
        case .loaded(let state):
            guard state.pipelineDigest == key.pipelineDigest else {
                // Stale-pipeline state reads as the reset it will become.
                return WindowStatus(
                    windowSize: Self.windowSize, verificationFailures: 0, userUndos: 0,
                    tripReason: nil)
            }
            let window = state.outcomes.suffix(Self.windowSize)
            return WindowStatus(
                windowSize: Self.windowSize,
                verificationFailures: window.filter { $0.kind == .verificationFailure }.count,
                userUndos: window.filter { $0.kind == .userUndo }.count,
                userRejections: window.filter { $0.kind == .userRejected }.count,
                tripReason: state.trip?.reason)
        }
    }

    // MARK: - Record

    /// Record one repair-run outcome for a configuration and return the
    /// verdict after it. Two verification failures (or two undos, or two
    /// rejected staged proposals) within the window trip the breaker; the
    /// trip stays until the pipeline changes. Unreadable state is NEVER
    /// overwritten — a damaged file stays tripped rather than healing itself
    /// into a clean one.
    @discardableResult
    public func record(_ kind: LintRepairOutcomeKind, for key: LintRepairBreakerKey) -> LintBreakerVerdict {
        lock.lock()
        defer { lock.unlock() }
        let url: URL
        switch stateFileURL(for: key) {
        case .failure(let unavailable):
            DebugLog.agent("lint breaker: cannot record \(kind.rawValue): \(unavailable.reason)")
            return .tripped(reason: unavailable.reason)
        case .success(let resolved):
            url = resolved
        }
        var state: State
        switch load(url) {
        case .unreadable(let reason):
            DebugLog.agent("lint breaker: \(reason) at \(url.path) — not overwriting; \(kind.rawValue) not recorded")
            return .tripped(reason: "breaker state unreadable")
        case .missing:
            state = Self.freshState(for: key)
        case .loaded(let existing):
            state = existing.pipelineDigest == key.pipelineDigest ? existing : Self.freshState(for: key)
        }
        let at = now()
        state.outcomes.append(Outcome(at: at, kind: kind))
        if state.outcomes.count > Self.windowSize {
            state.outcomes.removeFirst(state.outcomes.count - Self.windowSize)
        }
        if state.trip == nil, let reason = Self.tripReason(for: state.outcomes) {
            state.trip = Trip(trippedAt: at, reason: reason)
            DebugLog.agent("lint breaker: TRIPPED for \(key.provider)/\(key.model)/\(key.effort): \(reason)")
        }
        do {
            try write(state, to: url)
        } catch {
            DebugLog.agent("lint breaker: state write failed at \(url.path): \(error)")
        }
        if let trip = state.trip {
            return .tripped(reason: trip.reason)
        }
        return .clean
    }

    /// The trusted-host seam for the "Undo lint fixes" action: log a
    /// `userUndo` for the configuration that produced the undone run.
    @discardableResult
    public func recordUserUndo(for key: LintRepairBreakerKey) -> LintBreakerVerdict {
        record(.userUndo, for: key)
    }

    /// The trusted-host seam for a rejected staged proposal (tier 2): the
    /// human reviewed the hunks and said no. Repeated rejections trip the
    /// breaker with the same thresholds as undos.
    @discardableResult
    public func recordUserRejected(for key: LintRepairBreakerKey) -> LintBreakerVerdict {
        record(.userRejected, for: key)
    }

    // MARK: - Pure rules

    /// The trip reason for a window of outcomes, or nil while it stays clean.
    static func tripReason(for outcomes: [Outcome]) -> String? {
        let window = outcomes.suffix(windowSize)
        let failures = window.filter { $0.kind == .verificationFailure }.count
        if failures >= verificationFailureTripCount {
            return "\(failures) verification failures in the last \(window.count) repair runs"
        }
        let undos = window.filter { $0.kind == .userUndo }.count
        if undos >= userUndoTripCount {
            return "\(undos) user undos in the last \(window.count) repair runs"
        }
        let rejections = window.filter { $0.kind == .userRejected }.count
        if rejections >= userRejectedTripCount {
            return "\(rejections) staged proposals rejected in the last \(window.count) runs"
        }
        return nil
    }

    private static func freshState(for key: LintRepairBreakerKey) -> State {
        State(
            schema: stateSchema, pipelineDigest: key.pipelineDigest,
            provider: key.provider, model: key.model, effort: key.effort,
            outcomes: [], trip: nil)
    }

    // MARK: - Files

    private func stateFileURL(for key: LintRepairBreakerKey) -> Result<URL, BreakerUnavailable> {
        do {
            let container = try containerResolver()
            return .success(container
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent(key.stateFileName, isDirectory: false))
        } catch {
            return .failure(BreakerUnavailable(reason: "App Group container unavailable (\(error))"))
        }
    }

    private struct BreakerUnavailable: Error {
        let reason: String
    }

    private func load(_ url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(reason: "state file unreadable: \(error)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state: State
        do {
            state = try decoder.decode(State.self, from: data)
        } catch {
            return .unreadable(reason: "state file does not decode: \(error)")
        }
        guard state.schema == Self.stateSchema else {
            return .unreadable(reason: "unknown state schema \(state.schema)")
        }
        return .loaded(state)
    }

    private func write(_ state: State, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func discard(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // The next record() replaces a stale-pipeline file anyway; a
            // failed removal only leaves the file until then.
            DebugLog.agent("lint breaker: could not discard stale-pipeline state at \(url.path): \(error)")
        }
    }
}

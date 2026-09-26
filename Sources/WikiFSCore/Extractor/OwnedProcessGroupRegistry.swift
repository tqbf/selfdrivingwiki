import Foundation
import Synchronization
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The process-global registry of race-free process groups this process
/// launched and still owns (#1330).
///
/// A handle registers its verified group identity at spawn. It deregisters
/// when the kernel reports the group leader's exit, or when the handle goes
/// away. The registry therefore holds exactly the groups a quit path must
/// terminate: still alive, still owned, still verified.
///
/// Worker-task cancellation kills groups through
/// `RaceFreeProcessGroupHandle.result` on a cooperative-pool thread. A
/// process exit may not wait for that job. `terminateAllOwnedGroups()` is
/// the synchronous backstop for that gap: verified SIGTERM, one bounded
/// grace sleep, verified SIGKILL. It runs on the calling thread and uses no
/// cooperative scheduling. `kill` delivery does not depend on the caller
/// staying alive, so the signals land even though the process exits right
/// after the call.
public enum OwnedProcessGroupRegistry {
    /// One registered group: the leader pid plus the pinned identity that
    /// makes every later signal verified.
    struct Entry: Sendable, Equatable {
        let processID: Int32
        let identity: ProcessSignalSafety.Identity
        let parentProcessID: ProcessSignalSafety.PositivePID
    }

    /// How long a quit-time termination waits between SIGTERM and SIGKILL.
    /// The normal settle path uses the request's cancellation grace period
    /// (1 s). The quit backstop matches it so a wrapper that honors SIGTERM
    /// gets the same window it always had.
    public static let quitTerminationGracePeriod: Duration = .seconds(1)

    /// NSLock-equivalent via `Synchronization.Mutex` protects the map. Every
    /// access holds it. The termination actions run outside it.
    private static let entries = Mutex<[Int32: Entry]>([:])

    static func register(_ entry: Entry) {
        entries.withLock { $0[entry.processID] = entry }
    }

    static func deregister(processID: Int32) {
        _ = entries.withLock { $0.removeValue(forKey: processID) }
    }

    /// The leader pids currently registered. Test and diagnostics surface.
    public static var registeredProcessIDs: [Int32] {
        entries.withLock { Array($0.keys) }
    }

    /// What one quit-time termination pass did.
    public struct TerminationOutcome: Sendable, Equatable {
        /// Groups that received SIGTERM (and SIGKILL when still alive).
        public let terminatedGroupCount: Int
        /// Groups whose leader already exited, so no signal was needed.
        public let alreadyEndedGroupCount: Int
        /// Entries whose pid now wears a different process. Never signaled.
        public let unverifiedGroupCount: Int
    }

    /// The leader's state for one entry, from one observation.
    private enum LeaderState {
        case verifiedAlive
        case gone
        case replaced
    }

    /// Synchronously terminates every registered group: verified SIGTERM,
    /// one grace sleep, then verified SIGKILL for the groups still alive.
    /// Identity verification uses the same rule as the handle itself, so a
    /// recycled pid can never redirect a signal. Safe to call when nothing
    /// is registered (returns a zero outcome without sleeping).
    @discardableResult
    public static func terminateAllOwnedGroups(
        gracePeriod: Duration = quitTerminationGracePeriod,
        observe: @escaping @Sendable (ProcessSignalSafety.PositivePID) -> ProcessSignalSafety.Identity? =
            ProcessIdentityObservation.observe,
        signalGroup: @escaping @Sendable (Int32, Int32) -> Int32 = killVerifiedProcessGroup,
        sleep: @escaping @Sendable (Duration) -> Void = sleepSynchronously
    ) -> TerminationOutcome {
        // Sorted by pid so the pass order — and its diagnostics — is stable.
        let snapshot = entries.withLock { Array($0.values) }
            .sorted { $0.processID < $1.processID }
        guard !snapshot.isEmpty else {
            return TerminationOutcome(
                terminatedGroupCount: 0,
                alreadyEndedGroupCount: 0,
                unverifiedGroupCount: 0)
        }
        // Pass 1: SIGTERM every group whose leader is still the verified
        // process this registry launched.
        var liveEntries: [Entry] = []
        var ended = 0
        var unverified = 0
        for entry in snapshot {
            switch leaderState(of: entry, observe: observe) {
            case .verifiedAlive:
                _ = signalGroup(entry.processID, SIGTERM)
                liveEntries.append(entry)
            case .gone:
                ended += 1
            case .replaced:
                unverified += 1
                DebugLog.extraction(
                    "OwnedProcessGroupRegistry: quit termination skipped PID \(entry.processID): pid holds a different process")
            }
        }
        guard !liveEntries.isEmpty else {
            DebugLog.extraction(
                "OwnedProcessGroupRegistry: quit termination found no live owned group (\(snapshot.count) registered)")
            return TerminationOutcome(
                terminatedGroupCount: 0,
                alreadyEndedGroupCount: ended,
                unverifiedGroupCount: unverified)
        }
        sleep(gracePeriod)
        // Pass 2: SIGKILL the groups whose leader survived the grace period
        // as the same verified process.
        for entry in liveEntries where leaderState(of: entry, observe: observe) == .verifiedAlive {
            _ = signalGroup(entry.processID, SIGKILL)
        }
        DebugLog.extraction(
            "OwnedProcessGroupRegistry: quit termination signaled \(liveEntries.count) owned group(s) with SIGTERM, then SIGKILL where still alive")
        return TerminationOutcome(
            terminatedGroupCount: liveEntries.count,
            alreadyEndedGroupCount: ended,
            unverifiedGroupCount: unverified)
    }

    private static func leaderState(
        of entry: Entry,
        observe: @escaping @Sendable (ProcessSignalSafety.PositivePID) -> ProcessSignalSafety.Identity?
    ) -> LeaderState {
        guard let positivePID = ProcessSignalSafety.PositivePID(rawValue: entry.processID) else {
            return .gone
        }
        guard let observed = observe(positivePID) else { return .gone }
        guard observed == entry.identity else { return .replaced }
        return .verifiedAlive
    }

    /// Sends `signalNumber` to the process group led by `groupLeaderPID`.
    /// Returns 0 on delivery, `ESRCH` when the group is already gone, and
    /// any other errno so the caller can log it.
    public static func killVerifiedProcessGroup(groupLeaderPID: Int32, signalNumber: Int32) -> Int32 {
        let result = kill(-groupLeaderPID, signalNumber)
        return result == 0 ? 0 : errno
    }

    /// Blocks the calling thread for `duration`. The quit path cannot rely
    /// on cooperative scheduling, so the grace sleep is a plain thread sleep.
    public static func sleepSynchronously(for duration: Duration) {
        let components = duration.components
        let seconds = Double(max(components.seconds, 0))
            + Double(max(components.attoseconds, 0)) / 1_000_000_000_000_000_000
        Thread.sleep(forTimeInterval: max(seconds, 0))
    }
}

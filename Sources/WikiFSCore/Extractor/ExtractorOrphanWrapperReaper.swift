import Foundation
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

/// One process from the process table, reduced to what the reaper needs.
public struct ExtractorOrphanWrapperCandidate: Sendable, Equatable {
    public let processID: Int32
    public let processGroupID: Int32
    public let userID: UInt32
    /// The raw `KERN_PROCARGS2` blob: argv and environment as NUL-separated
    /// bytes. The blob, not just argv, is searched: both the command line
    /// and variables such as `HOME` carry the operation path.
    public let arguments: Data

    public init(
        processID: Int32,
        processGroupID: Int32,
        userID: UInt32,
        arguments: Data
    ) {
        self.processID = processID
        self.processGroupID = processGroupID
        self.userID = userID
        self.arguments = arguments
    }
}

/// Decides which processes are orphaned extractor wrappers (#1330).
///
/// An extractor wrapper process references its operation directory
/// (`…/extractors/v1/operations/<role>/<pid>-<uuid>/…`) in its command line
/// or environment. That path names the daemon generation that launched it.
/// A wrapper whose owning generation is dead does no work, holds memory, and
/// keeps a process slot forever. It is an orphan.
///
/// A command-line match alone is not proof. A process is an orphan only when
/// every one of these holds:
///
/// - it runs under the current user id;
/// - it is not the calling process;
/// - its process group id is greater than 1 (never signal group 0 or 1);
/// - its arguments reference an operation path under the given operations
///   root, with a role from the closed role set and a session name that
///   parses as `<pid>-<staging-id>`;
/// - the owning pid is dead, or the owning pid is the caller's own pid under
///   a different session id (pid reuse).
///
/// The decision is pure: process listing and signaling stay with the caller.
public enum ExtractorOrphanWrapperReaper {
    /// How many bytes after a path match the parser reads before it stops.
    /// A real operation path needs far less. This bound keeps a hostile or
    /// corrupt blob from stretching the scan.
    static let maximumPathComponentScanBytes = 1_024

    /// One process to kill, and the evidence that condemned it.
    public struct ReapDecision: Sendable, Equatable {
        public let processID: Int32
        public let processGroupID: Int32
        public let ownerProcessID: Int32
        public let role: ExtractorPackageProcessRole

        init(
            processID: Int32,
            processGroupID: Int32,
            ownerProcessID: Int32,
            role: ExtractorPackageProcessRole
        ) {
            self.processID = processID
            self.processGroupID = processGroupID
            self.ownerProcessID = ownerProcessID
            self.role = role
        }
    }

    /// Returns one decision per orphaned process, in candidate order.
    public static func reapDecisions(
        operationsRootPath: String,
        candidates: [ExtractorOrphanWrapperCandidate],
        currentProcessID: Int32,
        currentUserID: UInt32,
        currentSessionID: ExtractorStagingID,
        ownerIsAlive: (Int32) -> Bool
    ) -> [ReapDecision] {
        let needle = Data((operationsRootPath.standardizedOperationRootPath + "/").utf8)
        var decisions: [ReapDecision] = []
        for candidate in candidates {
            guard candidate.processID != currentProcessID,
                  candidate.userID == currentUserID,
                  ProcessSignalSafety.PositivePID(rawValue: candidate.processGroupID) != nil,
                  let decision = firstOrphanDecision(
                    for: candidate,
                    needle: needle,
                    currentProcessID: currentProcessID,
                    currentSessionID: currentSessionID,
                    ownerIsAlive: ownerIsAlive) else {
                continue
            }
            decisions.append(decision)
        }
        return decisions
    }

    /// Finds the first operation-path match in the blob that names a dead
    /// owner. `nil` when no match qualifies.
    private static func firstOrphanDecision(
        for candidate: ExtractorOrphanWrapperCandidate,
        needle: Data,
        currentProcessID: Int32,
        currentSessionID: ExtractorStagingID,
        ownerIsAlive: (Int32) -> Bool
    ) -> ReapDecision? {
        var searchRange = candidate.arguments.startIndex..<candidate.arguments.endIndex
        while let match = candidate.arguments.firstRange(of: needle, in: searchRange) {
            searchRange = match.upperBound..<candidate.arguments.endIndex
            if let decision = orphanDecision(
                at: match.upperBound,
                in: candidate.arguments,
                candidate: candidate,
                currentProcessID: currentProcessID,
                currentSessionID: currentSessionID,
                ownerIsAlive: ownerIsAlive) {
                return decision
            }
        }
        return nil
    }

    /// Parses `<role>/<session>/…` right after a matched operations root and
    /// applies the orphan rules.
    private static func orphanDecision(
        at index: Data.Index,
        in blob: Data,
        candidate: ExtractorOrphanWrapperCandidate,
        currentProcessID: Int32,
        currentSessionID: ExtractorStagingID,
        ownerIsAlive: (Int32) -> Bool
    ) -> ReapDecision? {
        // The match sits inside one NUL-terminated string of the blob. Read
        // a bounded window up to that string's end, then split it into path
        // components.
        let windowEnd = min(
            blob.endIndex,
            blob.index(index, offsetBy: maximumPathComponentScanBytes, limitedBy: blob.endIndex) ?? blob.endIndex)
        var window = blob[index..<windowEnd]
        if let terminator = window.firstIndex(of: 0) {
            window = window[window.startIndex..<terminator]
        }
        let components = window.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard components.count >= 2,
              let roleName = String(bytes: components[0], encoding: .utf8),
              let role = ExtractorPackageProcessRole(rawValue: roleName),
              let sessionName = String(bytes: components[1], encoding: .utf8),
              let session = ExtractorOperationSessionName.parse(sessionName) else {
            return nil
        }
        let ownerProcessID = session.processID
        let ownerIsDead: Bool
        if ownerProcessID == currentProcessID {
            // Pid reuse: this process holds the owner's pid, but the session
            // belongs to an earlier lifetime. It is an orphan when the
            // session is not the caller's own.
            ownerIsDead = session.stagingID != currentSessionID
        } else {
            ownerIsDead = !ownerIsAlive(ownerProcessID)
        }
        guard ownerIsDead else { return nil }
        return ReapDecision(
            processID: candidate.processID,
            processGroupID: candidate.processGroupID,
            ownerProcessID: ownerProcessID,
            role: role)
    }
}

private extension String {
    /// The operations root as it appears in a spawned child's arguments: the
    /// standardized absolute path, identical to what the executor pinned at
    /// launch (`ManagedExtractorProcessPaths` standardizes every root).
    var standardizedOperationRootPath: String {
        URL(fileURLWithPath: self).standardizedFileURL.path
    }
}

/// The imperative shell: lists same-user processes, asks the reaper core for
/// decisions, and kills the condemned groups (#1330).
///
/// The daemon calls this at startup, before
/// `cleanupOperationSessions(scope: .staleSessions)` deletes the operation
/// directories the orphans reference. The sweep covers every process role:
/// an `app`-role wrapper whose app died is as orphaned as a `daemon`-role
/// one, and a live owner of any role keeps its wrappers.
public enum ExtractorOrphanWrapperSweeper {
    /// What one sweep did.
    public struct Report: Sendable, Equatable {
        public let examinedProcessCount: Int
        public let reapedProcessGroupCount: Int
        public let reapedProcessIDs: [Int32]

        init(examinedProcessCount: Int, reapedProcessGroupCount: Int, reapedProcessIDs: [Int32]) {
            self.examinedProcessCount = examinedProcessCount
            self.reapedProcessGroupCount = reapedProcessGroupCount
            self.reapedProcessIDs = reapedProcessIDs
        }

        public static let empty = Report(examinedProcessCount: 0, reapedProcessGroupCount: 0, reapedProcessIDs: [])
    }

    /// Sweeps the process table and kills orphaned extractor wrapper groups.
    /// Returns what happened. Never throws: a sweep that cannot list
    /// processes logs and reports zero.
    @discardableResult
    public static func reapOrphanWrappers(
        operationsRoot: URL,
        currentSessionID: ExtractorStagingID,
        killGroup: (Int32, Int32) -> Bool = killOrphanGroup
    ) -> Report {
        #if os(macOS)
        let currentProcessID = getpid()
        let currentUserID = getuid()
        guard let candidates = listCurrentUserProcessCandidates() else {
            DebugLog.extraction("orphan wrapper sweep: process listing failed; no wrapper was reaped")
            return .empty
        }
        let decisions = ExtractorOrphanWrapperReaper.reapDecisions(
            operationsRootPath: operationsRoot.standardizedFileURL.path,
            candidates: candidates,
            currentProcessID: currentProcessID,
            currentUserID: currentUserID,
            currentSessionID: currentSessionID,
            ownerIsAlive: { ownerProcessID in
                if ownerProcessID == currentProcessID { return true }
                if kill(ownerProcessID, 0) == 0 { return true }
                // EPERM means the process exists but belongs to another
                // user. That is "alive" for a kill decision: never reap on
                // an owner we cannot prove dead.
                return errno == EPERM
            })
        var reaped: [Int32] = []
        for decision in decisions {
            if killGroup(decision.processGroupID, decision.processID) {
                reaped.append(decision.processID)
                DebugLog.extraction(
                    "orphan wrapper sweep: reaped pid \(decision.processID) (group \(decision.processGroupID), dead owner \(decision.ownerProcessID), role \(decision.role.rawValue))")
            } else {
                DebugLog.extraction(
                    "orphan wrapper sweep: could not signal pid \(decision.processID) (group \(decision.processGroupID), dead owner \(decision.ownerProcessID), role \(decision.role.rawValue))")
            }
        }
        return Report(
            examinedProcessCount: candidates.count,
            reapedProcessGroupCount: reaped.count,
            reapedProcessIDs: reaped)
        #else
        // Linux runs the daemon only as a diagnostic. There is no
        // KERN_PROCARGS2 there, so the sweep is macOS-only. The gap is loud.
        DebugLog.extraction("orphan wrapper sweep: not implemented on this platform; no wrapper was reaped")
        return .empty
        #endif
    }

    #if os(macOS)
    /// Lists the current user's processes with their `KERN_PROCARGS2` blobs.
    private static func listCurrentUserProcessCandidates() -> [ExtractorOrphanWrapperCandidate]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var processes = [kinfo_proc](
            repeating: kinfo_proc(),
            count: size / MemoryLayout<kinfo_proc>.stride)
        let result = processes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var candidates: [ExtractorOrphanWrapperCandidate] = []
        for index in 0..<min(count, processes.count) {
            let info = processes[index]
            let processID = info.kp_proc.p_pid
            guard processID > 1 else { continue }
            guard let arguments = processArguments(processID: processID) else { continue }
            candidates.append(ExtractorOrphanWrapperCandidate(
                processID: processID,
                processGroupID: info.kp_eproc.e_pgid,
                userID: info.kp_eproc.e_ucred.cr_uid,
                arguments: arguments))
        }
        return candidates
    }

    /// Reads one process's `KERN_PROCARGS2` blob (argc, argv, environment).
    /// `nil` for processes that cannot be read (zombies, other users).
    private static func processArguments(processID: Int32) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { pointer in
            sysctl(&mib, u_int(mib.count), pointer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        return Data(buffer[0..<size])
    }
    #endif

    /// Kills an orphan's process group. Falls back to the pid when the group
    /// is already gone. `true` means the target is dead or dying. `false`
    /// means the signal could not go out.
    public static func killOrphanGroup(processGroupID: Int32, processID: Int32) -> Bool {
        if kill(-processGroupID, SIGKILL) == 0 { return true }
        let groupErrno = errno
        if groupErrno == EPERM { return false }
        // ESRCH: the group is gone. The pid may live on outside it.
        if kill(processID, SIGKILL) == 0 { return true }
        // ESRCH here means the process is dead already. That is the goal.
        return errno == ESRCH
    }
}

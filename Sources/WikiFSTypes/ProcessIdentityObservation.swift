// pattern: Imperative Shell

import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Reads independent ownership and lifetime evidence from the operating system.
///
/// The parent PID and the kernel-recorded creation time together answer the
/// question a bare PID cannot: "is the process wearing this number still the one
/// I launched?" Equal PIDs with different creation times are different process
/// lifetimes, which is how a recycled PID is detected and refused.
///
/// Unsupported platforms fail closed by returning `nil`. Callers must treat
/// `nil` as "refuse to signal", so an unimplemented platform can never signal a
/// process it has not proven ownership of.
public enum ProcessIdentityObservation {
    public static func observe(processID: ProcessSignalSafety.PositivePID) -> ProcessSignalSafety.Identity? {
        #if os(macOS)
        importDarwinObservation(processID: processID)
        #elseif os(Linux)
        importLinuxObservation(processID: processID)
        #else
        nil
        #endif
    }

    #if os(macOS)
    private static func importDarwinObservation(
        processID: ProcessSignalSafety.PositivePID
    ) -> ProcessSignalSafety.Identity? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let resultSize = proc_pidinfo(
            processID.rawValue,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize))
        guard resultSize == Int32(expectedSize),
              info.pbi_pid == UInt32(processID.rawValue),
              let parentProcessID = ProcessSignalSafety.PositivePID(rawValue: Int32(info.pbi_ppid))
        else {
            return nil
        }
        return ProcessSignalSafety.Identity(
            processID: processID,
            parentProcessID: parentProcessID,
            startTime: .init(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec))
    }
    #endif

    #if os(Linux)
    /// Reads `/proc/<pid>/stat`. Field 4 is the parent PID and field 22 is the
    /// process start time in clock ticks since boot.
    ///
    /// Without a Linux observer, `observe` would return `nil` on Linux and every
    /// cancellation would fail closed — turning subprocess termination into a
    /// silent no-op rather than a safety guarantee.
    private static func importLinuxObservation(
        processID: ProcessSignalSafety.PositivePID
    ) -> ProcessSignalSafety.Identity? {
        // `try?` is correct here rather than swallowed error handling: the read
        // fails exactly when the process is gone (or /proc is unavailable), and
        // "cannot observe" is already the answer this function must return. The
        // caller treats nil as "refuse to signal". WikiFSTypes is a leaf module
        // with no DebugLog dependency, so the refusal is logged by the caller
        // (see AsyncProcessRunner.requestCancellation).
        // swiftlint:disable:next silent_try_optional
        guard let contents = try? String(
            contentsOfFile: "/proc/\(processID.rawValue)/stat", encoding: .utf8)
        else {
            return nil
        }
        let ticksPerSecond = UInt64(max(sysconf(Int32(_SC_CLK_TCK)), 1))
        return parseLinuxStat(
            contents, processID: processID, ticksPerSecond: ticksPerSecond)
    }
    #endif

    /// Split out from the file read, and compiled on every platform, so the
    /// field arithmetic can be unit-tested without a Linux host. Getting field
    /// 22 wrong would silently produce a constant start time, which would make
    /// every PID-reuse check pass.
    ///
    /// Field 2 (`comm`) is wrapped in parentheses and may itself contain spaces
    /// and parentheses, so everything up to the LAST `)` is skipped rather than
    /// splitting the whole line on whitespace.
    static func parseLinuxStat(
        _ contents: String,
        processID: ProcessSignalSafety.PositivePID,
        ticksPerSecond: UInt64
    ) -> ProcessSignalSafety.Identity? {
        guard let commEnd = contents.lastIndex(of: ")") else { return nil }

        // Field 1 must match the PID we asked about.
        let beforeComm = contents[contents.startIndex..<(contents.firstIndex(of: "(") ?? commEnd)]
        guard let reportedPID = Int32(beforeComm.trimmingCharacters(in: .whitespaces)),
              reportedPID == processID.rawValue
        else {
            return nil
        }

        let remainder = contents[contents.index(after: commEnd)...]
        // Split on any whitespace, not just " ": the line ends in "\n", which
        // would otherwise stay attached to field 22 and fail to parse.
        let fields = remainder.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)

        // `fields[0]` is field 3 (state), so field N is at index N - 3.
        let parentProcessIDIndex = 4 - 3
        let startTimeIndex = 22 - 3
        guard fields.count > startTimeIndex,
              let parentRaw = Int32(fields[parentProcessIDIndex]),
              let parentProcessID = ProcessSignalSafety.PositivePID(rawValue: parentRaw),
              let ticks = UInt64(fields[startTimeIndex])
        else {
            return nil
        }

        let divisor = max(ticksPerSecond, 1)
        return ProcessSignalSafety.Identity(
            processID: processID,
            parentProcessID: parentProcessID,
            startTime: .init(
                seconds: ticks / divisor,
                microseconds: (ticks % divisor) * 1_000_000 / divisor))
    }
}

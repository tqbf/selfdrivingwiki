// pattern: Imperative Shell

import Foundation
#if os(macOS)
import Darwin
#endif

/// Reads independent ownership and lifetime evidence from the operating system.
/// Unsupported platforms fail closed by returning `nil`.
public enum ProcessIdentityObservation {
    public static func observe(processID: ProcessSignalSafety.PositivePID) -> ProcessSignalSafety.Identity? {
        #if os(macOS)
        importDarwinObservation(processID: processID)
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
}

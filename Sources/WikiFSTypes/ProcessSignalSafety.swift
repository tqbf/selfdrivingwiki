// pattern: Functional Core

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Validates process signal targets independently of process creation and OS
/// observation. A numeric PID is never sufficient authority to signal.
public enum ProcessSignalSafety {
    public struct PositivePID: Sendable, Equatable {
        public let rawValue: Int32

        public init?(rawValue: Int32) {
            guard rawValue > 1 else { return nil }
            self.rawValue = rawValue
        }

        public init?(pidFileContents: String) {
            let trimmed = pidFileContents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int32(trimmed) else { return nil }
            self.init(rawValue: parsed)
        }
    }

    /// A kernel-observed creation timestamp. Equal PIDs with different start
    /// times represent different process lifetimes.
    public struct StartTime: Sendable, Equatable {
        public let seconds: UInt64
        public let microseconds: UInt64

        public init(seconds: UInt64, microseconds: UInt64) {
            self.seconds = seconds
            self.microseconds = microseconds
        }
    }

    /// Process ownership and lifetime evidence obtained from an OS observer.
    public struct Identity: Sendable, Equatable {
        public let processID: PositivePID
        public let parentProcessID: PositivePID
        public let startTime: StartTime

        public init(processID: PositivePID, parentProcessID: PositivePID, startTime: StartTime) {
            self.processID = processID
            self.parentProcessID = parentProcessID
            self.startTime = startTime
        }
    }

    public enum Refusal: Sendable, Equatable {
        case invalidPIDFileContents
        case identityUnavailable
        case identityMismatch
        case parentMismatch
    }

    public enum Outcome: Sendable, Equatable {
        case sent(result: Int32)
        case refused(Refusal)
    }

    public enum Verification: Sendable, Equatable {
        case verified
        case refused(Refusal)
    }

    public static func signalFromPIDFile(
        _ contents: String,
        expectedIdentity: Identity,
        expectedParentProcessID: PositivePID,
        observedIdentity: Identity?,
        signal: (Int32, Int32) -> Int32
    ) -> Outcome {
        guard let processID = PositivePID(pidFileContents: contents) else {
            return .refused(.invalidPIDFileContents)
        }
        return self.signal(
            processID: processID,
            expectedIdentity: expectedIdentity,
            expectedParentProcessID: expectedParentProcessID,
            observedIdentity: observedIdentity,
            signal: signal)
    }

    public static func signal(
        processID: PositivePID,
        expectedIdentity: Identity,
        expectedParentProcessID: PositivePID,
        observedIdentity: Identity?,
        signal: (Int32, Int32) -> Int32
    ) -> Outcome {
        switch verify(
            processID: processID,
            expectedIdentity: expectedIdentity,
            expectedParentProcessID: expectedParentProcessID,
            observedIdentity: observedIdentity) {
        case .verified:
            return .sent(result: signal(processID.rawValue, SIGKILL))
        case .refused(let refusal):
            return .refused(refusal)
        }
    }

    public static func verify(
        processID: PositivePID,
        expectedIdentity: Identity,
        expectedParentProcessID: PositivePID,
        observedIdentity: Identity?
    ) -> Verification {
        guard processID == expectedIdentity.processID else {
            return .refused(.identityMismatch)
        }
        guard expectedIdentity.parentProcessID == expectedParentProcessID else {
            return .refused(.parentMismatch)
        }
        guard let observedIdentity else {
            return .refused(.identityUnavailable)
        }
        guard observedIdentity == expectedIdentity else {
            return .refused(.identityMismatch)
        }
        return .verified
    }
}

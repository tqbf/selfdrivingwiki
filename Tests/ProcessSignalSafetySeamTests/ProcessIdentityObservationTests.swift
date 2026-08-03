import Foundation
import Testing
@testable import WikiFSTypes

/// Field-offset tests for the Linux `/proc/<pid>/stat` observer.
///
/// These run on every platform on purpose. The parser is the only part of the
/// identity observer that can be wrong *silently*: if field 22 were misread, the
/// start time would become a constant, every PID-reuse comparison would compare
/// equal, and the guard would approve signals it should refuse. macOS CI would
/// never notice, because the Darwin path uses `proc_pidinfo` instead.
struct ProcessIdentityObservationTests {
    /// Fields 3 through 22 of a plausible `/proc/<pid>/stat`, where field 22
    /// (starttime) is 987654 clock ticks.
    private static let fieldsThreeThroughTwentyTwo = [
        "S", // 3  state
        "1200", // 4  ppid
        "1234", // 5  pgrp
        "1200", // 6  session
        "34816", // 7  tty_nr
        "1234", // 8  tpgid
        "4194304", // 9  flags
        "100", // 10 minflt
        "0", // 11 cminflt
        "0", // 12 majflt
        "0", // 13 cmajflt
        "10", // 14 utime
        "5", // 15 stime
        "0", // 16 cutime
        "0", // 17 cstime
        "20", // 18 priority
        "0", // 19 nice
        "1", // 20 num_threads
        "0", // 21 itrealvalue
        "987654", // 22 starttime
    ]

    private func statLine(pid: Int32 = 1234, comm: String = "bash") -> String {
        "\(pid) (\(comm)) " + Self.fieldsThreeThroughTwentyTwo.joined(separator: " ") + "\n"
    }

    private func pid(_ rawValue: Int32) throws -> ProcessSignalSafety.PositivePID {
        try #require(ProcessSignalSafety.PositivePID(rawValue: rawValue))
    }

    @Test func readsParentPIDAndStartTimeFromTheCorrectFields() throws {
        let identity = try #require(ProcessIdentityObservation.parseLinuxStat(
            statLine(), processID: try pid(1234), ticksPerSecond: 100))

        #expect(identity.processID.rawValue == 1234)
        #expect(identity.parentProcessID.rawValue == 1200)
        // 987654 ticks at 100 Hz = 9876.54 s
        #expect(identity.startTime.seconds == 9876)
        #expect(identity.startTime.microseconds == 540_000)
    }

    /// `comm` is unsanitised kernel data: a process can name itself with spaces
    /// and parentheses. Splitting the whole line on whitespace, or on the FIRST
    /// `)`, shifts every later field.
    @Test(arguments: [
        "bash",
        "my proc",
        "weird)name",
        "(nested)",
        "a (b) c",
        ")",
    ])
    func toleratesCommContainingSpacesAndParentheses(comm: String) throws {
        let identity = try #require(ProcessIdentityObservation.parseLinuxStat(
            statLine(comm: comm), processID: try pid(1234), ticksPerSecond: 100))

        #expect(identity.parentProcessID.rawValue == 1200)
        #expect(identity.startTime.seconds == 9876)
    }

    @Test func differentStartTimesProduceDifferentIdentities() throws {
        let original = try #require(ProcessIdentityObservation.parseLinuxStat(
            statLine(), processID: try pid(1234), ticksPerSecond: 100))
        let recycled = try #require(ProcessIdentityObservation.parseLinuxStat(
            statLine().replacingOccurrences(of: "987654", with: "987655"),
            processID: try pid(1234),
            ticksPerSecond: 100))

        // Same PID, same parent, different lifetime: must not compare equal, or
        // a recycled PID would be accepted as the original child.
        #expect(original != recycled)
    }

    @Test func refusesAStatLineForADifferentPID() throws {
        #expect(ProcessIdentityObservation.parseLinuxStat(
            statLine(pid: 999), processID: try pid(1234), ticksPerSecond: 100) == nil)
    }

    @Test func refusesTruncatedOrMalformedInput() throws {
        let target = try pid(1234)
        #expect(ProcessIdentityObservation.parseLinuxStat(
            "", processID: target, ticksPerSecond: 100) == nil)
        #expect(ProcessIdentityObservation.parseLinuxStat(
            "1234 (bash) S 1200", processID: target, ticksPerSecond: 100) == nil)
        #expect(ProcessIdentityObservation.parseLinuxStat(
            "1234 (bash", processID: target, ticksPerSecond: 100) == nil)
        #expect(ProcessIdentityObservation.parseLinuxStat(
            "not-a-pid (bash) S 1200", processID: target, ticksPerSecond: 100) == nil)
    }

    /// PID 0 and 1 are never valid signal targets, so an init parent must not
    /// yield an identity that could later authorise a signal.
    @Test func refusesNonPositiveParentPID() throws {
        let orphaned = statLine().replacingOccurrences(
            of: "(bash) S 1200", with: "(bash) S 1")
        #expect(ProcessIdentityObservation.parseLinuxStat(
            orphaned, processID: try pid(1234), ticksPerSecond: 100) == nil)
    }

    @Test func toleratesAZeroTicksPerSecondWithoutDividingByZero() throws {
        let identity = try #require(ProcessIdentityObservation.parseLinuxStat(
            statLine(), processID: try pid(1234), ticksPerSecond: 0))
        #expect(identity.startTime.seconds == 987_654)
    }
}

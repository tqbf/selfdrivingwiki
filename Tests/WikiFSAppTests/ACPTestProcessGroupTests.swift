import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ACPTestProcessGroupTests {
    @Test func killsDescendantAfterGroupLeaderExits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-process-group-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let group = try ACPTestProcessGroup(directory: directory)
        defer {
            group.killGroup()
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Could not remove ACP process group fixture: \(error.localizedDescription)")
            }
        }

        let process = Process()
        process.executableURL = group.perlURL
        process.arguments = group.wrapperArguments(
            for: ["-e", "my $child = fork(); die 'fork failed' unless defined $child; exit 0 if $child; sleep 30;"])
        process.environment = ProcessInfo.processInfo.environment.merging(
            group.setRealAgent("/usr/bin/perl")) { _, testValue in testValue }

        try process.run()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while process.isRunning && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning, "the group leader must exit while its child remains")
        let groupID = try #require(group.processGroupID())
        group.killGroup()
        let cleanupDeadline = clock.now + .seconds(2)
        while kill(-groupID, 0) == 0 && clock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(-groupID, 0) == -1 && errno == ESRCH)
    }
}

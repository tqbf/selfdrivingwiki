import Foundation
import Testing
@testable import WikiFSCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererPackageStoreCoordinatorTests {
    @Test func twoCoordinatorInstancesSerializeAccess() async throws {
        let layout = try makeLayout("mutual-exclusion")
        let first = coordinator(layout: layout, token: "11111111-1111-1111-1111-111111111111")
        let second = coordinator(layout: layout, token: "22222222-2222-2222-2222-222222222222")
        let events = EventLog()

        async let firstResult: Void = first.withExclusiveAccess {
            await events.append("first-start")
            try await Task.sleep(for: .milliseconds(100))
            await events.append("first-end")
        }
        try await Task.sleep(for: .milliseconds(10))
        async let secondResult: Void = second.withExclusiveAccess {
            await events.append("second")
        }
        _ = try await (firstResult, secondResult)
        #expect(await events.values() == ["first-start", "first-end", "second"])
    }

    @Test func boundedTimeoutLeavesExistingLiveLockUntouched() async throws {
        let layout = try makeLayout("timeout")
        try writeOwnerLock(layout, now: Date(), token: "33333333-3333-3333-3333-333333333333")
        let policy = RendererEventPolicy(heartbeatInterval: 1, leaseExpiry: 45, clockSkewSafetyMargin: 15, cleanRetirementSafetyInterval: 1, lockAcquisitionTimeout: 0.05, orderedDrainBatchLimit: 1)
        let subject = RendererPackageStoreCoordinator(
            layout: layout,
            processIdentity: testIdentity,
            livenessChecker: FixedLiveness(isLive: true),
            tokenGenerator: FixedToken(value: "44444444-4444-4444-4444-444444444444"),
            policy: policy
        )
        do {
            try await subject.withExclusiveAccess {}
            Issue.record("Expected bounded lock acquisition to time out.")
        } catch let failure as RendererCoordinatorFailure {
            #expect(failure == .lockAcquisitionTimedOut)
        }
        #expect(FileManager.default.fileExists(atPath: layout.lockURL.path))
    }

    @Test func expiredNonLiveOwnerIsRecoveredAfterExpiryAndSkew() async throws {
        let layout = try makeLayout("stale")
        let now = Date(timeIntervalSince1970: 10_000)
        try writeOwnerLock(layout, now: now.addingTimeInterval(-61), token: "55555555-5555-5555-5555-555555555555")
        let subject = coordinator(layout: layout, now: now, token: "66666666-6666-6666-6666-666666666666", live: false)
        let value = try await subject.withExclusiveAccess { "acquired" }
        #expect(value == "acquired")
        #expect(FileManager.default.fileExists(atPath: layout.lockURL.path) == false)
    }

    @Test func expiredLiveOwnerIsNeverReclaimed() async throws {
        let layout = try makeLayout("live")
        let now = Date(timeIntervalSince1970: 10_000)
        try writeOwnerLock(layout, now: now.addingTimeInterval(-61), token: "77777777-7777-7777-7777-777777777777")
        let policy = RendererEventPolicy(heartbeatInterval: 1, leaseExpiry: 45, clockSkewSafetyMargin: 15, cleanRetirementSafetyInterval: 1, lockAcquisitionTimeout: 0.01, orderedDrainBatchLimit: 1)
        let subject = coordinator(layout: layout, now: now, token: "88888888-8888-8888-8888-888888888888", live: true, policy: policy)
        await #expect(throws: RendererCoordinatorFailure.staleOwnerStillLive) {
            try await subject.withExclusiveAccess {}
        }
    }

    @Test func cancellationDuringAcquisitionDoesNotCreateOwnership() async throws {
        let layout = try makeLayout("cancellation")
        try writeOwnerLock(layout, now: Date(), token: "99999999-9999-9999-9999-999999999999")
        let subject = coordinator(layout: layout, token: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", live: true)
        let task = Task { try await subject.withExclusiveAccess {} }
        try await Task.sleep(for: .milliseconds(25))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: layout.lockURL.path))
    }

    @Test func throwingBodyReleasesLock() async throws {
        let layout = try makeLayout("throw")
        let subject = coordinator(layout: layout, token: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        await #expect(throws: TestFailure.self) {
            try await subject.withExclusiveAccess { throw TestFailure() }
        }
        #expect(FileManager.default.fileExists(atPath: layout.lockURL.path) == false)
    }

    @Test func malformedOwnerRecordFailsClosed() async throws {
        let layout = try makeLayout("malformed")
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: layout.lockURL)
        let subject = coordinator(layout: layout, token: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        await #expect(throws: RendererCoordinatorFailure.malformedOwnerRecord) {
            try await subject.withExclusiveAccess {}
        }
        #expect(FileManager.default.fileExists(atPath: layout.lockURL.path))
    }

    private func makeLayout(_ name: String) throws -> RendererPackageStoreLayout {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-coordinator-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try RendererPackageStoreLayout(appGroupContainerRoot: root)
    }

    private func coordinator(layout: RendererPackageStoreLayout, now: Date = Date(), token: String, live: Bool = false, policy: RendererEventPolicy = .phase3Default) -> RendererPackageStoreCoordinator {
        RendererPackageStoreCoordinator(layout: layout, clock: FixedClock(now: now), processIdentity: testIdentity, livenessChecker: FixedLiveness(isLive: live), tokenGenerator: FixedToken(value: token), policy: policy)
    }

    private func writeOwnerLock(_ layout: RendererPackageStoreLayout, now: Date, token: String) throws {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let record = try RendererCoordinatorOwnerRecord(processIdentity: testIdentity, now: now, ownerToken: token)
        try JSONEncoder().encode(record).write(to: layout.lockURL)
    }

    private var testIdentity: RendererProcessIdentity { RendererProcessIdentity(processID: 42, executableIdentity: "test", hostIdentity: "test-host", bootSessionIdentity: "test-session") }
}

private struct FixedClock: RendererCoordinatorClock { let nowValue: Date; init(now: Date) { nowValue = now }; func now() -> Date { nowValue } }
private struct FixedLiveness: RendererProcessLivenessChecking { let isLive: Bool; func isLive(_: RendererProcessIdentity) -> Bool { isLive } }
private struct FixedToken: RendererCoordinatorOwnerTokenGenerating { let value: String; func nextOwnerToken() -> String { value } }
private struct TestFailure: Error {}
private actor EventLog { private var storage: [String] = []; func append(_ value: String) { storage.append(value) }; func values() -> [String] { storage } }

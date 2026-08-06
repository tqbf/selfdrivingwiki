import Foundation
import Testing
@testable import WikiFSCore

@Suite("Renderer failure window", .serialized, .timeLimit(.minutes(1)))
struct RendererFailureWindowTests {
    @Test func countedFailuresAtThresholdEnableSafeModeAndPersist() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()

        var index = try await store.read()
        for minute in [0, 4, 9] {
            let result = try await store.recordInstalledRendererFailure(
                packageID: fixture.packageID,
                version: fixture.version,
                failure: .loadTimedOut,
                expectedGeneration: index.generation,
                clock: RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: minute))
            )
            index = result.index
        }

        #expect(index.safeModeIsEnabled)
        let reopened = try await RendererMachineIndexStore(layout: fixture.layout).read()
        #expect(reopened.safeModeIsEnabled)
    }

    @Test func agingPrunesFailuresOutsideNamedWindow() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()
        var index = try await store.read()

        for minute in [0, 1, 11] {
            let result = try await store.recordInstalledRendererFailure(
                packageID: fixture.packageID,
                version: fixture.version,
                failure: .entryNavigationFailed,
                expectedGeneration: index.generation,
                clock: RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: minute))
            )
            index = result.index
        }

        #expect(index.safeModeIsEnabled == false)
        let agedClock = RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 11))
        let agedWindow = try await store.failureWindow(packageID: fixture.packageID, version: fixture.version, clock: agedClock)
        #expect(agedWindow.count == 2)
    }

    @Test func windowIncludesItsExactStartAndExcludesOlderFailures() throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let atZero = try RendererMachineStoreFailureFixture.timestamp(minutes: 0)
        let atTen = try RendererMachineStoreFailureFixture.timestamp(minutes: 10)
        let failure = RendererInstalledRendererFailure(
            packageID: fixture.packageID,
            version: fixture.version,
            cause: .loadTimedOut,
            occurredAt: atZero
        )

        #expect(try rendererInstalledRendererFailuresPruned([failure], now: atTen.date()).count == 1)
        #expect(try rendererInstalledRendererFailuresPruned(
            [failure],
            now: atTen.date().addingTimeInterval(1)
        ).isEmpty)
    }

    @Test func readySessionDoesNotClearPriorFailures() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()
        let initial = try await store.read()
        let clock = RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0))
        let first = try await store.recordInstalledRendererFailure(
            packageID: fixture.packageID,
            version: fixture.version,
            failure: .loadTimedOut,
            expectedGeneration: initial.generation,
            clock: clock
        )
        var session = WikiAppWebViewSessionStateMachine(sessionID: .init(rawValue: UUID()))
        let didStart = session.start()
        #expect(didStart)
        session.markReady(sessionID: session.sessionID)

        #expect(session.state == .ready(session.sessionID))
        let window = try await store.failureWindow(packageID: fixture.packageID, version: fixture.version, clock: clock)
        #expect(window.count == first.window.count)
    }

    @Test func nonCountedSessionFailuresHaveNoPersistenceCause() {
        #expect(RendererSessionFailureKind.invalidEntryURL.installedRendererFailureCause == nil)
        #expect(RendererSessionFailureKind.concurrencyLimitReached.installedRendererFailureCause == nil)
        #expect(RendererSessionFailureKind.navigationFailed.installedRendererFailureCause == .entryNavigationFailed)
        #expect(RendererSessionFailureKind.bridgeBootstrapFailed.installedRendererFailureCause == .bridgeBootstrapFailed)
    }

    @Test(arguments: [
        (RendererSessionFailureKind.loadTimedOut, RendererInstalledRendererFailureCause.loadTimedOut),
        (RendererSessionFailureKind.navigationFailed, .entryNavigationFailed),
        (RendererSessionFailureKind.bridgeBootstrapFailed, .bridgeBootstrapFailed),
        (RendererSessionFailureKind.webContentProcessTerminated, .webContentProcessTerminated),
    ])
    func sessionFailureRecorderPersistsEachCountedCause(
        kind: RendererSessionFailureKind,
        expectedCause: RendererInstalledRendererFailureCause
    ) async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()
        let failure = RendererSessionFailure(sessionID: .init(rawValue: UUID()), kind: kind)
        let clock = RendererMachineStoreFailureFixture.Clock(
            timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0)
        )

        let result = try await store.recordRendererSessionFailure(
            reservation: .init(packageID: fixture.packageID, version: fixture.version),
            failure: failure,
            clock: clock
        )

        let recorded = try #require(result)
        #expect(recorded.window.count == 1)
        #expect(recorded.index.installedRendererFailures == [
            .init(
                packageID: fixture.packageID,
                version: fixture.version,
                cause: expectedCause,
                occurredAt: try RendererMachineStoreFailureFixture.timestamp(minutes: 0)
            ),
        ])
    }

    @Test func sessionFailureRecorderRejectsNonCountedKindsBeforePersistence() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()
        let initial = try await store.read()

        let result = try await store.recordRendererSessionFailure(
            reservation: .init(packageID: fixture.packageID, version: fixture.version),
            failure: .init(sessionID: .init(rawValue: UUID()), kind: .invalidEntryURL),
            clock: RendererMachineStoreFailureFixture.Clock(
                timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0)
            )
        )

        #expect(result == nil)
        #expect(try await store.read() == initial)
    }

    @Test func sessionFailureRecorderCallbackPersistsTheBoundInstalledVersion() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()
        let clock = RendererMachineStoreFailureFixture.Clock(
            timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0)
        )
        let recorder = store.sessionFailureRecorder(clock: clock)
        let reservation = RendererPackageReservation(
            packageID: fixture.packageID,
            version: fixture.version
        )

        await recorder(
            .init(sessionID: .init(rawValue: UUID()), kind: .webContentProcessTerminated),
            reservation
        )

        #expect(try await store.failureWindow(
            packageID: fixture.packageID,
            version: fixture.version,
            clock: clock
        ).count == 1)
    }

    @Test func retainedFailureHistoryHasANamedBound() throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let failure = RendererInstalledRendererFailure(
            packageID: fixture.packageID,
            version: fixture.version,
            cause: .loadTimedOut,
            occurredAt: try RendererMachineStoreFailureFixture.timestamp(minutes: 0)
        )
        let oversized = Array(repeating: failure, count: RendererInstalledRendererFailurePolicy.maximumRetainedFailures + 1)
        let retained = try rendererInstalledRendererFailuresPruned(oversized, now: failure.occurredAt.date())

        #expect(retained.count == RendererInstalledRendererFailurePolicy.maximumRetainedFailures)
    }

    @Test func v2MigrationPreservesDescriptorsSafeModeAndGeneration() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()
        let initial = try await store.read()
        let safe = try await store.mutate(expectedGeneration: initial.generation) { _, safeModeIsEnabled in
            safeModeIsEnabled = true
        }
        try fixture.writeV2IndexForMigration(safe)

        let migrated = try await RendererMachineIndexStore(layout: fixture.layout).read()
        #expect(migrated.schemaVersion == RendererMachineIndex.currentSchemaVersion)
        #expect(migrated.generation == safe.generation)
        #expect(migrated.safeModeIsEnabled)
        #expect(migrated.records == safe.records)
        #expect(migrated.installedRendererFailures.isEmpty)
    }

    @Test(arguments: RendererInstalledRendererFailureCause.allCases)
    func eachExplicitlyCountedFailureParticipatesInTheWindow(_ failure: RendererInstalledRendererFailureCause) async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()
        let initial = try await store.read()

        let result = try await store.recordInstalledRendererFailure(
            packageID: fixture.packageID,
            version: fixture.version,
            failure: failure,
            expectedGeneration: initial.generation,
            clock: RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0))
        )

        #expect(result.index.generation == initial.generation + 1)
        #expect(result.window.count == 1)
    }

    @Test func concurrentStoresRejectStaleFailureUpdateWithoutLosingFirstWrite() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let first = try await fixture.installedStore()
        let second = RendererMachineIndexStore(layout: fixture.layout)
        let generation = (try await first.read()).generation
        let clock = RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0))

        _ = try await first.recordInstalledRendererFailure(packageID: fixture.packageID, version: fixture.version, failure: .bridgeBootstrapFailed, expectedGeneration: generation, clock: clock)
        await #expect(throws: RendererMachineIndexStoreError.staleGeneration) {
            try await second.recordInstalledRendererFailure(packageID: fixture.packageID, version: fixture.version, failure: .webContentProcessTerminated, expectedGeneration: generation, clock: clock)
        }

        let window = try await first.failureWindow(packageID: fixture.packageID, version: fixture.version, clock: clock)
        #expect(window.count == 1)
    }

    @Test func retriedSecondStoreUpdatePreservesBothFailures() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let first = try await fixture.installedStore()
        let second = RendererMachineIndexStore(layout: fixture.layout)
        let generation = (try await first.read()).generation
        let clock = RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0))

        let firstUpdate = try await first.recordInstalledRendererFailure(packageID: fixture.packageID, version: fixture.version, failure: .loadTimedOut, expectedGeneration: generation, clock: clock)
        let secondUpdate = try await second.recordInstalledRendererFailure(packageID: fixture.packageID, version: fixture.version, failure: .bridgeBootstrapFailed, expectedGeneration: firstUpdate.index.generation, clock: clock)

        #expect(secondUpdate.window.count == 2)
        #expect((try await first.read()).installedRendererFailures.count == 2)
    }

    @Test func simultaneousTwoStoreUpdatesCommitOnlyOneGeneration() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let first = try await fixture.installedStore()
        let second = RendererMachineIndexStore(layout: fixture.layout)
        let generation = (try await first.read()).generation
        let clock = RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0))

        async let firstSucceeded: Bool = {
            do {
                _ = try await first.recordInstalledRendererFailure(packageID: fixture.packageID, version: fixture.version, failure: .loadTimedOut, expectedGeneration: generation, clock: clock)
                return true
            } catch {
                return false
            }
        }()
        async let secondSucceeded: Bool = {
            do {
                _ = try await second.recordInstalledRendererFailure(packageID: fixture.packageID, version: fixture.version, failure: .bridgeBootstrapFailed, expectedGeneration: generation, clock: clock)
                return true
            } catch {
                return false
            }
        }()

        #expect(([await firstSucceeded, await secondSucceeded].filter { $0 }).count == 1)
        #expect((try await first.failureWindow(packageID: fixture.packageID, version: fixture.version, clock: clock)).count == 1)
    }
}

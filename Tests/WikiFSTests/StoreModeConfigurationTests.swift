#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiCtlCore
import WikiFSEngine

/// Pins the `allowLocalStore` flag's contract (plans/daemon-only-access.md,
/// "Flag name and polarity" + the Phase 3 gate): the DEFAULT resolves
/// REMOTE in every configuration, the override is DEBUG-only (compile-time
/// — a shipping build cannot enable local store access), and a daemon
/// failure CANNOT flip the mode (launch-fixed; the failure surfaces typed).
///
/// The flag itself is a launch-fixed `static let` — the tests therefore pin
/// the polarity through `StoreModeConfiguration.captureAllowLocalStore`
/// (the pure capture function the launch capture consumed) and the
/// `overrideCompiledIn` compile-time constant, and pin the launch-fixed
/// accessor's stability across a daemon-down store call.
@Suite("Store mode configuration", .timeLimit(.minutes(2)))
struct StoreModeConfigurationTests {

    // MARK: (a) default resolves REMOTE in every configuration

    @Test("default resolves REMOTE in every configuration")
    func defaultResolvesRemoteInEveryConfiguration() {
        // No override present: false in DEBUG AND release — the shipping
        // default is remote everywhere.
        #expect(
            StoreModeConfiguration.captureAllowLocalStore(environment: [:])
                == false)
        // The resolved mode derives from the flag by the documented
        // polarity (true = LOCAL, false = daemon).
        #expect(
            StoreModeConfiguration.resolvedMode
                == (StoreModeConfiguration.allowLocalStore ? .local : .remote))

        // The test process itself runs without the override, so the
        // launch-fixed accessor IS the shipping default: remote. (A
        // developer exporting WIKI_ALLOW_LOCAL_STORE into the test
        // environment gets this named failure instead of a silent pass.)
        #expect(
            !StoreModeConfiguration.allowLocalStore,
            "the test process must not run with \(StoreModeConfiguration.overrideEnvironmentVariable) set — it flips the launch-fixed mode under test")
        #expect(StoreModeConfiguration.resolvedMode == .remote)
    }

    // MARK: (b) the override is DEBUG-only (compile-time)

    @Test("the override is DEBUG-only: release reads false unconditionally")
    func overrideIsDebugOnlyCompileTime() {
        // The compile-time constant exposed for tests mirrors the flag
        // source's `#if DEBUG` blocks; this file re-derives the same
        // compile-time answer so the pair MUST agree.
        #if DEBUG
        let compiledWithDebugConfiguration = true
        #else
        let compiledWithDebugConfiguration = false
        #endif
        #expect(
            StoreModeConfiguration.overrideCompiledIn
                == compiledWithDebugConfiguration)

        // The env override selects LOCAL only when it is compiled in
        // (DEBUG); a release build ignores the variable entirely.
        let overrideEnv = [
            StoreModeConfiguration.overrideEnvironmentVariable: "1"
        ]
        #expect(
            StoreModeConfiguration.captureAllowLocalStore(environment: overrideEnv)
                == compiledWithDebugConfiguration)
        let wordOverrideEnv = [
            StoreModeConfiguration.overrideEnvironmentVariable: "true"
        ]
        #expect(
            StoreModeConfiguration.captureAllowLocalStore(environment: wordOverrideEnv)
                == compiledWithDebugConfiguration)

        // Only the documented values enable it — anything else (and any
        // unrelated variable) stays remote in every configuration.
        let offEnv = [StoreModeConfiguration.overrideEnvironmentVariable: "0"]
        #expect(
            StoreModeConfiguration.captureAllowLocalStore(environment: offEnv)
                == false)
        let unknownValueEnv = [
            StoreModeConfiguration.overrideEnvironmentVariable: "yes"
        ]
        #expect(
            StoreModeConfiguration.captureAllowLocalStore(environment: unknownValueEnv)
                == false)
        let unrelatedEnv = ["OTHER_FLAG": "1"]
        #expect(
            StoreModeConfiguration.captureAllowLocalStore(environment: unrelatedEnv)
                == false)
    }

    // MARK: (c) daemon failure cannot flip the mode

    /// A daemon-down store call surfaces a TYPED error and the launch-fixed
    /// mode accessor still reads remote afterwards — the mode is captured
    /// once at process start and is never a response to daemon failure.
    /// The wedged-selector fixture is the `RemoteWikiStoreTests` daemon-down
    /// shape: neither reply nor error handler fires, so the transport's
    /// timeout backstop answers typed.
    @Test("a daemon-down store call surfaces typed and never flips the mode")
    func daemonFailureCannotFlipTheMode() async throws {
        #expect(StoreModeConfiguration.resolvedMode == .remote)
        let modeBeforeTheFailure = StoreModeConfiguration.resolvedMode

        let store = RemoteWikiStore(
            transport: XPCStoreTransport(
                invoker: { _, _, _ in /* never replies — the daemon is down */ },
                timeout: 0.2),
            wikiID: WikiID(rawValue: "store-mode-daemon-down"),
            callDeadline: RemoteWikiStore.defaultCallDeadline)
        do {
            _ = try await store.resolveTitleToID("anything")
            Issue.record("expected the daemon-down store call to fail typed")
        } catch let error as RemoteStoreClientError {
            // Typed transport failure (deadlineExceeded), not a crash, not
            // a silent local revival.
            guard case .deadlineExceeded = error else {
                Issue.record("expected .deadlineExceeded, got \(error)")
                return
            }
        } catch {
            Issue.record("expected RemoteStoreClientError, got \(error)")
        }

        // The mode is launch-fixed: the failure changed nothing.
        #expect(StoreModeConfiguration.resolvedMode == modeBeforeTheFailure)
        #expect(StoreModeConfiguration.resolvedMode == .remote)
    }
}
#endif

import Foundation
import Testing
import WikiFSCore
@testable import WikiCtlCore
@testable import WikiFSEngine

#if os(macOS)

/// Pins the store-mode contract (plans/daemon-only-access.md, P5
/// sole-writer milestone). The `allowLocalStore` flag and its
/// `WIKI_ALLOW_LOCAL_STORE` DEBUG override are DELETED at P5 — there is no
/// capture function, no environment variable, and no compile-time override
/// constant to test anymore. The suite therefore pins:
/// 1. the resolved mode is REMOTE — an unconditional constant (compile-level:
///    any reference to the deleted flag members is a compile error), and
/// 2. a daemon-down store call surfaces a TYPED error and the mode still
///    reads remote afterwards — the mode is a constant, so nothing can flip
///    it (the polarity's "never a response to daemon failure" property holds
///    by construction).
@Suite("Store mode configuration", .timeLimit(.minutes(2)))
struct StoreModeConfigurationTests {

    // MARK: (a) the mode is REMOTE, unconditionally (override deleted)

    @Test("the resolved mode is REMOTE — the override no longer exists")
    func resolvedModeIsRemoteUnconditionally() {
        // P5: `StoreModeConfiguration.resolvedMode` is a `static let`
        // constant pinned to `.remote`. The flag members the old suite
        // exercised (`allowLocalStore`, `captureAllowLocalStore`,
        // `overrideEnvironmentVariable`, `overrideCompiledIn`) are DELETED —
        // referencing them here would be a compile error, which IS the
        // deletion's pin: the override cannot be re-enabled, not even in
        // DEBUG.
        #expect(StoreModeConfiguration.resolvedMode == .remote)
    }

    // MARK: (b) daemon failure cannot flip the mode

    /// A daemon-down store call surfaces a TYPED error and the mode still
    /// reads remote afterwards. The mode is a constant, so nothing can flip
    /// it — the test keeps the runtime half of the old contract observable
    /// (typed failure, no crash, no silent local revival). The wedged
    /// selector is the `RemoteWikiStoreTests` daemon-down shape: neither
    /// reply nor error handler fires, so the transport's timeout backstop
    /// answers typed.
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

        // The mode is a constant: the failure changed nothing.
        #expect(StoreModeConfiguration.resolvedMode == modeBeforeTheFailure)
        #expect(StoreModeConfiguration.resolvedMode == .remote)
    }
}
#endif

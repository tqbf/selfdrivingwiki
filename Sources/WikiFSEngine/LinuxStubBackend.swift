#if !os(macOS)
import Foundation
import WikiFSCore

/// A no-op `AgentBackend` for non-macOS platforms (Linux CI).
///
/// The real backend is `ACPBackend` (macOS-only — depends on the `ACP` product
/// which uses `ACPProcessManager` and `os.log`). On Linux, `WikiFSEngine`
/// compiles with this stub as the default `AgentLauncher.backend` value so the
/// type resolves. It is never actually driven — the Linux CI builds the
/// portable `WikiFSCoreTests` target only, and every test file that references
/// `AgentLauncher` is `#if os(macOS)`-guarded (#754, #780).
///
/// All methods either return a minimal value or throw — a call to any of them
/// on Linux indicates a logic error (the only code path that should reach
/// `AgentLauncher` on Linux is type resolution, not execution).
struct LinuxStubBackend: AgentBackend {
    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        throw LinuxStubError.unsupportedOnLinux
    }

    func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func resume(
        sessionID: String,
        profile: BackendProfile
    ) async throws -> SessionHandle? {
        nil
    }

    func cancel(_ session: SessionHandle) async {}
}

enum LinuxStubError: Error, LocalizedError {
    case unsupportedOnLinux

    var errorDescription: String? {
        "LinuxStubBackend cannot start agent sessions (ACP is macOS-only)"
    }
}
#endif

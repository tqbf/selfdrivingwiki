import WikiFSEngine

/// Test isolation for `AgentProviderRuntime`'s login-shell `PATH` seam (#1368).
///
/// `AgentProviderRuntime.init(resolveLoginShellPATH:)` defaults to the
/// production `PathPreflight.loginShellPATH()`, which spawns a real login
/// shell. A test that leaves the default in place therefore starts a
/// subprocess from a process-free unit test, and under a starved cooperative
/// pool that hop can outrun a test's bounded poll — `disposalDuringPreparation
/// RemovesScratchAndRefuses` failed in CI on exactly that.
///
/// Inject this resolver at every construction site instead. It answers with a
/// constant, so the seam still runs but no login shell does.
enum AgentProviderRuntimeTestSupport {
    /// A fixed `PATH` for the summarizer/title spawn shape.
    ///
    /// The value is arbitrary — no test asserts it. Tests that DO assert the
    /// resolved `PATH` (or its absence) inject their own resolver rather than
    /// this one.
    static let stubLoginShellPATH: AgentProviderRuntime.LoginShellPATHResolver = {
        "/usr/bin:/bin"
    }
}

#if os(macOS)
import Foundation
import WikiFSEngine

// The `allowLocalStore` flag — ONE definition (plans/daemon-only-access.md,
// "Flag name and polarity"). This file is the single source of truth for the
// flag's capture; every consumer reads the RESOLVED mode from
// ``StoreModeConfiguration/resolvedMode``, never the environment directly.
//
// Polarity: `true` selects LOCAL store access, `false` selects the daemon.
//
// Mechanics, per the plan's permitted-access table (P3 column onward):
// - DEFAULT = `false` (remote) in every configuration.
// - `true` is reachable ONLY in DEBUG builds, through the
//   `WIKI_ALLOW_LOCAL_STORE` environment variable; release builds read
//   `false` unconditionally, so a shipping build cannot enable local store
//   access at all.
// - The value is captured ONCE at process start and never re-evaluated: a
//   daemon failure (or anything else) can never flip the mode mid-run. A
//   daemon-down session stays remote and surfaces typed errors.
// - The flag is deleted at the Phase 5 close (sole-writer milestone); P7's
//   source guards assert its absence.
public enum StoreModeConfiguration {
    /// The environment variable the DEBUG override reads.
    public static let overrideEnvironmentVariable = "WIKI_ALLOW_LOCAL_STORE"

    /// Compile-time answer for tests: whether the DEBUG override is compiled
    /// in AT ALL. `true` in DEBUG, `false` in release — mirrors the
    /// `#if DEBUG` blocks in this source, so a test can pin the mechanics
    /// without parsing source text.
    public static let overrideCompiledIn: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// The launch capture the process-fixed ``allowLocalStore`` consumed at
    /// first access. Exposed as a pure function so tests can pin BOTH the
    /// default (no override → false in every configuration) and the
    /// DEBUG-only behavior of the override against synthetic environments.
    public static func captureAllowLocalStore(
        environment: [String: String]
    ) -> Bool {
        #if DEBUG
        // DEBUG-only developer override: WIKI_ALLOW_LOCAL_STORE=1 (or
        // true) selects the local store for this process run.
        let raw = environment[overrideEnvironmentVariable]
        return raw == "1" || raw == "true"
        #else
        // Release: the override does not exist; local is never selected.
        _ = environment
        return false
        #endif
    }

    /// `allowLocalStore`: `true` = LOCAL, `false` = daemon (remote).
    /// Captured once — `static let` evaluates the initializer exactly once
    /// per process; no code path re-reads the environment afterwards.
    public static let allowLocalStore: Bool = captureAllowLocalStore(
        environment: ProcessInfo.processInfo.environment)

    /// The mode every composition consumes (app wiring, session
    /// composition). Derived from the launch-fixed flag — nothing else.
    public static let resolvedMode: StoreAccessMode =
        allowLocalStore ? .local : .remote
}
#endif

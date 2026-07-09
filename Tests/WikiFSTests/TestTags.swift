import Testing

/// Marks a test suite as a slow SQLite **integration** test (issue #292), so it
/// can be excluded from per-commit CI.
///
/// **Important:** `swift test` (SwiftPM) does NOT yet filter by tag — its
/// `--skip`/`--filter` match test names by regex only (tag filtering is
/// xcodebuild-only, 16.3+). So CI excludes these suites *by name* via a regex
/// that mirrors this tag — see `.github/workflows/ci.yml` and `AGENTS.md`. The
/// tag still earns its keep: it documents intent, enables IDE/xcodebuild local
/// filtering (`xcodebuild -skip-testing-tags integration`), and future-proofs CI
/// for when SwiftPM gains `--skip .integration`.
///
/// Apply `.tags(.integration)` to suites that open a real SQLite store and are
/// too slow for per-commit CI — notably the N+1 working-set paths (issue #291).
/// When you do, ALSO append the suite name to the CI skip regex so it is
/// actually excluded. Pure-logic tests stay untagged so they always run in CI.
extension Tag {
    @Tag static var integration: Tag
}

import Testing

/// Marks a test suite as a slow SQLite **integration** test (issue #292), so it
/// can be excluded from per-commit CI.
///
/// **Important:** `swift test` (SwiftPM) does NOT yet filter by tag — its
/// `--skip`/`--filter` match test names by regex only (tag filtering is
/// xcodebuild-only, 16.3+). CI has two Swift jobs (issue #364):
/// 1. `swift` (fast tier) — excludes these suites by name via a `--skip`
///    regex for quick PR feedback.
/// 2. `swift-integration` — runs the full `swift test` (no skip), so these
///    suites gate merges. Promote it to a required status check in branch
///    protection so a failing AC test blocks merge.
/// The tag still earns its keep: it documents intent, enables IDE/xcodebuild
/// local filtering (`xcodebuild -skip-testing-tags integration`), and
/// future-proofs CI for when SwiftPM gains `--skip .integration`.
///
/// Apply `.tags(.integration)` to suites that open a real SQLite store and are
/// too slow for per-commit CI — notably the N+1 working-set paths (issue #291).
/// When you do, ALSO append the suite name to the fast-tier `--skip` regex in
/// `.github/workflows/ci.yml` so it is excluded from quick PR feedback (it will
/// still run in the `swift-integration` job). Pure-logic tests stay untagged so
/// they always run in the fast tier.
extension Tag {
    @Tag static var integration: Tag
}

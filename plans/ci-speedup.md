# Plan: Fix Swift CI — stop the test hang + stop cache eviction

Two **independent, confirmed** problems make the swift CI job take 27-45 min and
**FAIL every run**. Fix both in one PR. (Root causes confirmed from run logs:
Build succeeds ~10 min; the Test step hangs — a `CheckedContinuation` test never
resumes under Swift Testing's default parallel pool, the documented #664 bug —
and goes silent ~3 min in, killed at the 30-min timeout. Separately, the build
cache is fully evicted: the key includes `hashFiles('Sources/**/*.swift')` so
~25 PR branches blow past GitHub's 10GB/repo LRU and every run cold-builds MLX
C++ (~1374 units).)

## P0-2 — Stop the test hang (test sources)
Add a per-suite `.timeLimit` to the unguarded continuation suites, mirroring the
proven `ACPPermissionTimeoutTests` fix (#664, which uses `.serialized,
.timeLimit(.minutes(5))`). **First read each suite's current `@Suite(...)` traits
and confirm it uses `CheckedContinuation`/real `Task`s**, then:
- `QueueExtractionTests` → `@Suite(.serialized, .timeLimit(.minutes(2)))`
- `ACPTurnRecoveryTests` → `@Suite(.serialized, .timeLimit(.minutes(2)))`
- `ACPWiringTests` → `@Suite(.serialized, .timeLimit(.minutes(2)))`
- `QueueEngineTests` → already `.serialized`; ADD `.timeLimit(.minutes(2))`
- (If a suite does NOT use continuations/real Tasks, `.timeLimit(.minutes(2))`
  alone suffices — apply the minimal correct guard. Goal: **no suite can hang >2 min**.)
- Reference `ACPPermissionTimeoutTests.swift` for the pattern.

## P0-1 — Stop cache eviction (`ci.yml` cache key)
Key the cache on `Package.resolved` **ONLY** (drop the `Sources/**/*.swift` hash).
One entry per dep set instead of one per commit → stops the 10GB LRU eviction →
warm build ~2 min (was ~15 min cold). Remove the `restore-keys` (all-or-nothing
per `Package.resolved`; a stale partial restore is worse than a clean cold build).

## P1-3 + P1-4 — `ci.yml` build/test steps
Remove the fragile probe (`if xcrun swift build 2>/dev/null; then SWIFT=xcrun
swift; else swift build; SWIFT=swift; fi`) — the `2>/dev/null` swallows failure
reasons and the `else` can trigger a second full build. The "Select Xcode" step
already does `sudo xcode-select -s`, so use one toolchain directly. Add
`--parallel` (safe now that P0-2's per-suite `.timeLimit` guards ship in this PR).

### Exact `ci.yml` diff (the `swift` job's cache/build/test steps)
```yaml
      - name: Cache Swift build
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/Library/Caches/org.swift.swiftpm
          # CHANGED: key on Package.resolved ONLY. Stops the cache-entry
          # explosion that evicted every cache and forced cold builds.
          key: ${{ runner.os }}-swift-${{ hashFiles('Package.resolved') }}
          # restore-keys removed (all-or-nothing per dep set).

      - name: Build
        # CHANGED: removed the xcrun/swift probe + 2>/dev/null. One toolchain.
        run: xcrun swift build

      - name: Test (full suite — in-memory fixtures, #658)
        timeout-minutes: 30
        # CHANGED: --parallel (safe: per-suite .timeLimit guards in P0-2 bound any hang to ~2 min).
        run: xcrun swift test --parallel
```
Remove the now-unused `$SWIFT` env-export logic entirely. Keep the `checkout`,
`Select Xcode`, `Environment`, and `Generate codegen files (make version prompts)`
steps unchanged. Do NOT touch the `python` job.

## Files
- `.github/workflows/ci.yml` — cache key (P0-1), build/test steps (P1-3, P1-4).
- Test suites (P0-2): `QueueExtractionTests`, `ACPTurnRecoveryTests`,
  `ACPWiringTests`, `QueueEngineTests` (locate exact paths).

## Acceptance
- `make build && make test` passes locally; no suite hangs (the 4 guarded suites
  now have `.timeLimit`).
- **The PR's own CI run is the proof**: the swift job PASSES (no 30-min hang).
  Note: the FIRST run after the cache-key change may still be slower as the new
  `Package.resolved`-keyed cache populates; subsequent runs go warm (~2-min
  build). The headline signal is that it PASSES and finishes, not the 30-min timeout.
- Cache key no longer includes the Sources hash; the probe is gone.
- No bare `try?`; no `print`; do NOT merge to main.

## Build/test
`make build && make test`. Push the branch, open a PR. Scratch in `tmp/` inside
your own worktree.

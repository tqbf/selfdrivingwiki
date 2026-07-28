---
timestamp: 2026-07-22T014021Z
title: "2026-07-21 — Linux CI: portable core-libs + macOS-only API guards (branch `linux-ci`, PR #780)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-21 — Linux CI: portable core-libs + macOS-only API guards (branch `linux-ci`, PR #780)

## Progress


**Outcome.** Got the `linux-swift` CI run to the test-execution stage — the
build phase (WikiFSCoreTests + all transitive deps) now passes on Linux.
Left as a follow-up: confirm the wikid Linux fix via CI (GitHub Actions
stopped triggering for this branch mid-session — likely free-minute quota
on the tqbf repo).

**Pattern.** Swift CoreLibs on Linux splits some macOS-`Foundation` modules
into separate SwiftPM modules. The split modules need conditional imports:
- `FoundationXML` — XMLParser, XMLParserDelegate (TimedTextTranscript,
  TTMLTranscript)
- `FoundationNetworking` — URLSession, URLRequest, HTTPURLResponse
  (11 WikiFSCore Integrations files + 2 WikiFSTests files)
- `Crypto` (from swift-crypto) — SHA256 (PortableHash.swift wrapper)
- `CSQLite` system module — wraps `<sqlite3.h>` for `import SQLite3`
  (WikiFSCore + both test targets).

The established pattern is `#if canImport(X) import X #endif` so macOS
(where the symbol is re-exported from Foundation) is unaffected.

**Other macOS-only API guards added.**
- `WikiDaemonProtocol` — `@objc` XPC protocol (guard whole file with
  `#if os(macOS)`).
- `WikiDaemonConnection` — NSXPCConnection/NSXPCInterface (guard whole
  file).
- `DarwinNotifier` — CFNotificationCenterGetDarwinNotifyCenter (guard
  body, leave public enum visible).
- `DatabaseLocation.extensionContainerDirectory` — containerURL
  (guard body, return nil).
- `TabBarLayout` / `ZoomScale` — replaced `CGFloat` with `Double`
  (CGFloat on Linux resolves to a Duration via the overloaded `rounded`
  family, causing type-checking failures).
- `EmbeddingMetaCutoverTests` — replaced `NLEmbedder.identifier` with
  its literal "nlembedding-512" (NLEmbedder is macOS-only).
- `SourceMaterializerTests` — removed unused `import CryptoKit`.

**Package.swift changes.**
- Added `swift-crypto` as a direct dep (was already transitive via GRDB;
  declared directly so `WikiFSCore` can depend on the `Crypto` product
  conditionally on Linux).
- Added `CSQLite` (conditional, Linux-only) to both `WikiFSCore` and
  `WikiFSCoreTests`.
- Filtered `podcast-token-helper` out of the target list on Linux
  (Obj-C executable that `#includes` Foundation/Foundation.h and links
  AppleMediaServices private framework — neither available on Linux).
- `WikiFSEngine` target is now a macOS-only dep of `WikiFSCoreTests`
  (it depends on the macOS-only `ACP` product).

**wikid rewrite.** The `#else // Linux` JSON-RPC-over-stdio branch of
`wikid/main.swift` had two Swift 6 strict-concurrency issues on the
Linux toolchain (with `-warnings-as-errors`):
1. `cannot find 'req' in scope` — the `else` branch referenced `req`
   which is only bound when its `guard`-pattern let succeeds.
2. `reference to var 'stdout' is not concurrency-safe` — the C stdio
   `stdout` global is shared mutable state.
Restructured: decode into an optional parsed dict first, extract `id`
(always available), guard on `req` for the success path; wrap stdout
writes via FileHandle.standardOutput in a `writeResponse` helper.

**Tests verified on macOS.** Full `swift test`: 3359 tests, all green.
`swift test` after each change.

**Pending.** Confirm the wikid Linux fix on the actual Linux toolchain
via CI. The GitHub Actions workflow stopped firing for new pushes to
the `linux-ci` branch around 20:48Z — likely an Actions free-minute
quota on the tqbf account (no `queued` or `in_progress` runs; the push
event webhook wasn't creating a new run). Need to either wait for the
quota to reset (monthly) or have the repo owner re-enable Actions.

## Verification

Historical verification remains in the progress record above.

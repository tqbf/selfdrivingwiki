---
timestamp: 2026-11-27T03:00:00Z
title: "Language-neutral app–daemon contract with gRPC — first slice"
branch: "feature/app-daemon-grpc-contract"
status: "implemented-first-slice"
---

# Language-neutral app–daemon contract with gRPC — first slice

The implementation base for this note is `plans/app-daemon-wire-contract.md`
and the schemas' own rulebook, `Protocol/app-daemon/README.md`.

## Progress

- **First slice implemented and green; families NOT migrated.** The XPC
  workload route stays production; the gRPC surface serves the first-slice
  read/event family (`AdmitSession`, `GetCapabilities`, `ListWikis`,
  `SubscribeEvents` with the registry family only — store/queue/chat field
  numbers are reserved).
- **Schemas + governance** (`Protocol/app-daemon/`): versioned package
  `wikid.appdaemon.v1` with distinct ID wrapper messages, `Timestamp` time
  units, unknown-safe enums, explicit presence, reserved evolutions, and a
  versioned `ErrorDetails` message with stable numeric codes. `buf.yaml`
  lints (STANDARD, with two documented naming exceptions) and breaks
  against the committed descriptor baseline
  (`baseline/image.binpb`). `tools.lock.json` pins protoc 36.2, Buf 1.75.0,
  swift-protobuf 1.41.0, and grpc-swift-protobuf 2.5.0 with SHA-256
  digests; `make app-daemon-tools` verifies and installs them, and
  `make check-app-daemon-proto` regenerates the committed Swift bindings,
  checks drift, lints, breaks, and runs the negative test (a removed field
  without reservation must fail the breaking check — verified to fail).
- **Daemon runtime** (`Sources/WikiDaemonGRPC/`, new module): the listener
  binds `g/s` under a mode-0700 directory inside the App Group container
  (short names; a `sockaddr_un`-overflowing path is a typed failure before
  bind — the overlong case is unit-tested), takes the process-lifetime
  exclusive flock BEFORE touching the socket (second listener = typed
  ownership failure; stale socket recovery under the guard is tested), and
  tears down in the contract order (stop accepting → revoke sessions +
  close streams → unlink under the guard → release). The session store
  issues 256-bit credentials over the new XPC admission selector, keeps
  them in process memory only, never logs them, exchanges idempotently
  within the 30 s bootstrap window (one logical session per XPC
  connection; expired bootstrap + fresh XPC admission reuses the live
  session — all unit-tested with an injected monotonic clock), and
  revokes + terminates streams on XPC invalidation. The registry event hub
  publishes at the same call site as the XPC firehose with a monotonic
  per-daemon sequence; the subscription forwards through a bounded loop
  and fails typed (`RESYNC_REQUIRED`) at the bound.
- **Client runtime**: `AppDaemonSessionClient` (transport, bearer
  metadata, explicit per-call deadlines, client-side 4 MiB response bound,
  capabilities gate rejecting version/instance/capability mismatches typed)
  plus the `WikiCtlCore` typed registry adapter. Generated code is
  committed (`Protocol/app-daemon/generated/swift`, `Visibility=Public`,
  no warnings-as-errors on that target); ordinary `swift build` needs no
  codegen tools.
- **Rust peer** (`tools/app-daemon-interop/`): tonic 0.14.6 / prost 0.14.4
  with committed `Cargo.lock` and a pinned `rust-toolchain.toml`
  (1.96.0). Bindings generate at crate build time from the same schemas
  (`cargo:rerun-if-changed` covers the external proto tree; the make
  target passes the digest-verified protoc). `serve` is the fixture
  server; `probe` validates the Swift server; both compare decoded
  values and presence against the shared corpus
  (`Protocol/app-daemon/fixtures/corpus.json`) — never raw bytes.
- **Tests** (Swift Testing, `.serialized` + `.timeLimit`):
  `AppDaemonSessionStoreContractTests` (7, pure), `AppDaemonAdmissionTests`
  (4, live sockets: ownership, stale recovery, full round trip, typed
  failures), `AppDaemonRustInteropTests` (8, both roles: corpus list
  values+presence incl. the non-ASCII display name and page-id presence,
  typed event stream, oversized reply failing at the declared bound,
  incompatible capabilities failing the handshake typed, injected
  wiki-not-found details round trip — in BOTH directions), and the source
  contracts `AppDaemonProtoCoverageTests` +
  `AppDaemonBootstrapOnlyContractTests` (every schema RPC has a provider
  handler + client path + corpus family; the only post-contract XPC
  addition is the admission selector, and it is payload-free).
- **CI**: required-job steps added WITHOUT `continue-on-error` — pinned
  tool install + digest check, proto checks, `cargo build --locked`
  interop peer, the opt-in gRPC suites, and the source-contract suites.

## Verification

- `make build` — full package builds and the signed app bundles
  (including the new targets; Swift tools bumped 6.0 → 6.1 for
  grpc-swift-2 2.4.4).
- `swift test --filter AppDaemonSessionStoreContractTests` — 7/7 passed.
- `SWIFT_TEST_NUM_WORKERS=1 WIKIFS_APP_TESTS=1 swift test --filter
  AppDaemonAdmissionTests` — 4/4 passed.
- `SWIFT_TEST_NUM_WORKERS=1 WIKIFS_APP_TESTS=1 WIKIFS_INTEROP_PEER=…
  swift test --filter AppDaemonRustInteropTests` — 8/8 passed (both
  roles).
- `swift test --filter 'AppDaemonProtoCoverageTests|AppDaemonBootstrapOnlyContractTests'`
  — passed.
- `scripts/app-daemon-proto.sh check` — drift none, lint clean, breaking
  compatible, negative breaking edit correctly rejected.
- Rust peer standalone smoke: serve+probe normal, oversize, incompatible,
  injected-error modes all pass (`probe` exit 0 in all four).
- AC.1 harness build: `swift build --product AppDaemonSmoke` clean,
  swiftlint strict clean, `ProcessSignalSafetyAuditTests` green with the
  smoke's reviewed signal call site.
- **Not yet run (recorded honestly)**: the signed cold-launch smoke's
  recorded evidence. The harness is now COMPLETE
  (`Sources/AppDaemonSmoke` + `make test-signed-app-daemon-grpc`): it
  installs the signed app, then drives XPC admission → gRPC session →
  ListWikis → live registry event (scratch wiki created + deleted over
  the legacy route) → verified daemon stop (`proc_pidpath` identity +
  TERM; the process-control audit ledger covers the call site) →
  reconnect to a NEW daemon instance, with TCP audits before and after.
  Running it replaces this machine's installed app (`make install`
  behavior) and stops the running instance — the operator's call. The
  paired benchmark (`make benchmark-app-daemon-grpc`) still needs its
  measurement harness, which lands with the family-migration PR when the
  gRPC route carries real workload; cutover REQUIRES both recorded
  evidence trails (AC.1, AC.6).

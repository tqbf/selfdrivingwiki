---
timestamp: 2026-11-27T05:30:00Z
title: "Language-neutral app–daemon contract with gRPC — first slice"
branch: "feature/app-daemon-grpc-contract"
status: "implemented-first-slice-reviewed"
---

# Language-neutral app–daemon contract with gRPC — first slice

The implementation base for this note is `plans/app-daemon-wire-contract.md`
and the schemas' own rulebook, `Protocol/app-daemon/README.md`.

## Progress

- **First slice implemented, independently reviewed, findings fixed;
  families NOT migrated.** The XPC workload route stays production; the
  gRPC surface serves the first-slice read/event family (`AdmitSession`,
  `GetCapabilities`, `ListWikis`, `SubscribeEvents` with the registry
  family only — store/queue/chat field numbers are reserved).
- **Schemas + governance** (`Protocol/app-daemon/`): versioned package
  `wikid.appdaemon.v1`, distinct ID wrappers, `Timestamp` time units,
  unknown-safe enums, explicit presence, reserved evolutions, versioned
  `ErrorDetails` with stable numeric codes. `buf.yaml` lints (STANDARD
  with two documented naming exceptions) and breaks against the committed
  descriptor baseline. `tools.lock.json` pins protoc 36.2, Buf 1.75.0,
  swift-protobuf 1.41.0, grpc-swift-protobuf 2.5.0 with SHA-256 digests;
  `make app-daemon-tools` verifies and installs them, and
  `make check-app-daemon-proto` regenerates the committed Swift bindings,
  checks drift, lints, breaks, runs a POSITIVE control on an unchanged
  copy, then the negative test (a removed field without reservation must
  fail — verified to fail).
- **Daemon runtime** (`Sources/WikiDaemonGRPC/`): listener binds `g/s`
  under a mode-0700 App Group directory (short names; path overflow is a
  typed failure before bind), flock guard before bind, contract-ordered
  teardown whose guard fd is TRANSFERRED to the teardown task (completion
  no longer depends on the listener instance). Session store issues
  256-bit credentials over the XPC admission selector, mint is serialized
  against XPC invalidation (a liveness predicate runs under the store
  lock; a post-mint listener-liveness re-check revokes a just-minted
  session if the listener stopped in between), 30 s idempotent exchange,
  one session per connection, revocation terminating streams, never
  logged. The registry event hub publishes at the same call site as the
  XPC firehose with a monotonic stamp serialized under the hub lock;
  per-subscriber buffers are BOUNDED and overflow is observable — a full
  buffer ends that subscriber's stream without the revocation sentinel
  and the provider fails the RPC typed (`RESYNC_REQUIRED`) based on the
  consumed `TerminalReason`. Revocation also cancels the RPC's
  cancellation handle.
- **Client runtime**: session state (bearer + verified instance id)
  publishes ATOMICALLY only after both handshake legs succeed; four-way
  instance agreement (XPC admission / AdmitSession reply / capabilities
  reply / bound instance); unknown event oneofs and unknown numeric kinds
  fail the stream typed (never guessed); foreign `ErrorDetails` versions
  and non-exact Any URLs are skipped in both languages; close() is atomic
  (terminal flag + task snapshot under one lock) and cancels owned
  subscription tasks.
- **Rust peer** (`tools/app-daemon-interop/`): tonic 0.14.6 / prost
  0.14.4, pinned toolchain (1.96.0), committed `Cargo.lock`, codegen from
  the same schemas. `serve`/`probe` compare decoded values and presence
  against the shared corpus in both roles; the probe verifies the details
  code and version explicitly.
- **AC.1 harness complete** (`Sources/AppDaemonSmoke` +
  `make test-signed-app-daemon-grpc`): installs the signed app, then
  drives XPC admission → gRPC session → ListWikis → live registry event
  (scratch wiki created + deleted over the legacy route) → verified
  daemon stop (`proc_pidpath` identity + TERM, covered in the
  process-control audit ledger) → reconnect to a NEW instance, with TCP
  audits before and after.
- **Independent review (model-diversity policy)**: the implementation was
  authored by the GLM executor family; an OpenAI-family reviewer ran
  three passes. Round 1: BLOCK (2 criticals). Round 2: BLOCK (1 new
  critical — hub deadlock — plus partials). Round 3: remaining HIGHs
  (overflow fan-out, terminal-reason growth, probe fd leaks, serve clean
  exit, mint-vs-stop race, teardown guard ownership) — ALL fixed in this
  iteration. Known transport limitation documented: server-side
  revocation ends the subscription logically and the client resyncs on
  reconnect; the grpc-swift 2 public API provides no reverse interruption
  of a writer already suspended in transport flow control (such a writer
  unwinds at the client's deadline or cancel).

## Verification

- `make build` — full package builds and the signed app bundles.
- `make test` — full suite passes.
- gRPC suites: session-store contract 7/7, live admission 4/4, interop
  both roles 8/8, source contracts 13/13, signal audit 8/8.
- `scripts/app-daemon-proto.sh check` — positive control passes, negative
  breaking edit rejected, drift none, lint clean.
- Rust peer standalone: all four modes exit 0.
- swiftlint strict: zero violations across all new/changed Swift.
- **Not yet run (operator's call)**: the signed smoke's recorded evidence
  (running `make test-signed-app-daemon-grpc` replaces this machine's
  installed app and stops the running instance). The paired benchmark's
  measurement harness lands with the family-migration PR. Cutover
  REQUIRES both recorded evidence trails (AC.1, AC.6) plus this PR's
  merge.

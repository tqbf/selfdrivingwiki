# App–daemon wire contract over gRPC

Status: **first slice implemented, families NOT migrated** (the XPC
workload route stays production until family parity passes — see
`plans/daemon-only-access.md` and the step list below).

## What this is

The language-neutral contract between the app and the bundled `wikid`
daemon: Protocol Buffers schemas under `Protocol/app-daemon/proto`, served
by the daemon over a Unix domain socket with gRPC (gRPC Swift 2 + its POSIX
HTTP/2 transport), consumed by the app through typed session adapters, and
proven language-neutral by a Rust peer (tonic/prost) that speaks the same
schemas in both roles.

Design decisions and review gates live in the approved plan; this doc maps
them onto the code. The language-neutral semantic rules and transport
boundaries are stated next to the schemas in
`Protocol/app-daemon/README.md`.

## First slice (this change)

- **Schemas** `Protocol/app-daemon/proto/wikid/appdaemon/v1/`:
  `AdmitSession`, `GetCapabilities`, `ListWikis`, `SubscribeEvents`
  (registry family only; store/queue/chat numbers reserved). Versioned
  package `wikid.appdaemon.v1`; the error taxonomy is a versioned
  `ErrorDetails` message with stable numeric codes carried in gRPC status
  details.
- **Daemon side** `Sources/WikiDaemonGRPC/`: the listener (`g/s` under the
  App Group container, mode-0700 directory, flock guard before bind, no
  TCP), the session store (XPC-issued 256-bit credentials, 30 s bootstrap
  window, idempotent exchange, revocation terminating streams), the
  service provider, and the registry event hub fed at the same call site
  as the XPC firehose.
- **XPC keeps admission**: one new selector (`grpcAdmission`) hands out the
  endpoint path + bootstrap credential, bound to the XPC connection; XPC
  invalidation revokes the session. No workload crosses XPC beyond what
  already did.
- **Client side** `Sources/WikiDaemonGRPC/AppDaemonSessionClient.swift` +
  `Sources/WikiCtlCore/DaemonGRPCSession.swift`: bootstrap → capabilities
  gate → typed calls; explicit per-call deadlines; client-side 4 MiB
  bound; no auto-retries.
- **Rust peer** `tools/app-daemon-interop/`: `serve` (fixture server for
  the Swift client) and `probe` (validates the Swift server), both driven
  by the shared corpus `Protocol/app-daemon/fixtures/corpus.json`.

## Verification (all local, all green)

| Gate | Command |
|---|---|
| Session store semantics + typed-failure mapping | `swift test --filter AppDaemonSessionStoreContractTests` |
| Live socket: ownership, stale recovery, round trip, revocation | `make test-app-daemon-grpc` |
| Rust↔Swift both roles over the corpus | `make test-app-daemon-interop` |
| Schema drift / lint / breaking / negative breaking edit | `make check-app-daemon-proto` |
| Bootstrap-only XPC surface + schema coverage | `swift test --filter 'AppDaemonProtoCoverageTests|AppDaemonBootstrapOnlyContractTests'` |

`make test-app-daemon-interop` fails when the peer binary is missing for
the selected tier — build it first with `make app-daemon-interop`.

## What is deliberately NOT here yet

- **Family migration** (store, queue, chat) — step 3 of the plan. The
  subscriber-cursor replacement, per-family adapters, parity fixtures, and
  the development switch belong to that step.
- **Cutover** — step 4. The legacy workload selectors stay on XPC; the
  gRPC surface serves the first-slice read/event family only.
- **Signed smoke + paired benchmark** — the make targets exist
  (`test-signed-app-daemon-grpc`, `benchmark-app-daemon-grpc`) and their
  harness scripts document the local procedure; they require a developer
  Mac with `signing/local.config` and a quiet machine. Cutover requires
  their recorded evidence (AC.1, AC.6).

## Toolchain pins

`Protocol/app-daemon/tools.lock.json` pins protoc 36.2, Buf 1.75.0,
swift-protobuf 1.41.0, grpc-swift-protobuf 2.5.0 with SHA-256 digests;
`make app-daemon-tools` installs and verifies them. The Rust toolchain is
pinned by `tools/app-daemon-interop/rust-toolchain.toml` (1.96.0) and
crate versions by the committed `Cargo.lock` (`cargo build --locked`).
The baseline descriptor image `Protocol/app-daemon/baseline/image.binpb`
is the breaking-check gate — regenerate only after compatibility review.

# Agent sandbox invocation scoping

Status: approved (operator decisions recorded 2026-10-22 — see §13).
Implementation: Phases 0–1 implemented on `feature/agent-sandbox-scoping` (PR #1470) — Phase 0 at `da3b8b74`, Phase 1 at `2ece6a4b`. Scoped production launches remain DISABLED; per-run endpoints, Seatbelt rules, managed-run wiring, and credential delivery are Phases 2–3. Deviations recorded in §11 under each phase.
Author: OpenAI-family (codex/gpt-6.1-sol), reviewing GLM-family migration work.
Baseline: `ab44c06d`, branch `feature/wikictl-fixture-target`. Recheck line numbers after the stacked branches land.
Decision record: all five §13 decisions approved as recommended on 2026-10-22. Implementation queues behind the fixture-binary split; rollout per §11 (Phase 0 lands with the stack, Phases 1–4 as their own stacked change).
Holding location: `tmp/` — land as `plans/agent-sandbox-scoping.md` with PLAN.md index entry once decisions are recorded.

## 1. Purpose

Restore enforced wiki scope after the CLI-to-daemon migration. Keep the child filesystem fence. Do not move database ownership back into the CLI.

Use two controls:

- Seatbelt restricts direct child filesystem access and daemon endpoint access.
- The daemon checks each request against the registered run scope.

Do not treat a rendered wiki selector as authorization.

## 2. Current behavior

The domain envelope uses version 1. It carries a request ID, family, operation, and optional payload. It carries no authorization value (`Sources/WikiDaemonContract/DaemonDomainWire.swift:33–35,75–98`).

The listener checks the peer's effective user ID before it reads bytes. Its handler receives only `Data` (`Sources/wikid/DaemonSearchSocketServer.swift:276–305`).

The dispatcher checks the envelope version, then routes by family. Command families reach daemon-side execution (`Sources/wikid/DaemonDomainSocketDispatcher.swift:56–85`).

The production profile permits reads, network access, and process execution by default. It denies filesystem writes, then adds write allowances (`Sources/WikiFSCore/Core/SandboxProfile.swift:133–178`).

Those allowances include the assigned wiki database and its sidecars. They can also include `queue.sqlite` and its sidecars (`Sources/WikiFSCore/Core/SandboxProfile.swift:151–169`).

The profile also permits Claude runtime state and temporary files (`Sources/WikiFSCore/Core/SandboxProfile.swift:139–150`). It narrows execution-vector writes through additional rules (`Sources/WikiFSCore/Core/SandboxProfile.swift:158–160`).

The run context renders trusted selectors and absolute helper paths. Its current contract treats environment values as conveniences, not credentials (`Sources/WikiFSEngine/AgentRunContext.swift:70–90,178–185`).

The migration moved file-backed operations into the daemon too. For example, `source export` writes using caller-provided paths (`Sources/wikid/DaemonDomainCommands.swift:300–310`).

## 3. Threat model

### Adversary

The adversary is a prompt-injected or buggy agent child. It runs as the user. It can execute arbitrary commands available to its process.

Assume the child can change arguments, remove environment values, construct protocol frames, and read its own capability. Do not trust the bundled CLI to enforce policy.

Consider both Seatbelt-enabled and unsandboxed launches. State different guarantees for these modes.

### Assets

- Other wikis' data and metadata.
- Original raw-source bytes and their recorded history.
- Host files outside approved runtime and scratch paths.
- The assigned wiki and its revision history.
- The daemon's registry, global queue controls, and run credentials.

### Previous guarantee

The old direct-database path used the child's kernel write fence. A child assigned wiki A could not directly mutate wiki B's database through the normal confined process tree.

The exact-file allowances show that boundary (`Sources/WikiFSCore/Core/SandboxProfile.swift:151–169`). The broad read policy did not protect other wiki reads (`Sources/WikiFSCore/Core/SandboxProfile.swift:133–145`).

This was not a complete same-user security boundary. The normal profile allowed process execution. The strict profile separately identifies external launch and automation pivots (`Sources/WikiFSCore/Core/SandboxProfile.swift:332–349`).

### Migration regression

The daemon executes writes outside the child's Seatbelt profile. Its socket checks user identity, not assigned wiki identity (`Sources/wikid/DaemonDomainSocketDispatcher.swift:80–85`, `Sources/wikid/DaemonSearchSocketServer.swift:276–305`).

A confined child can therefore request a write to another wiki through the daemon. This regresses the previous direct-write boundary.

CAS checks remain necessary. They prevent stale updates, not unauthorized updates. Typed CAS errors already exist (`Sources/WikiDaemonContract/DaemonDomainWire.swift:172–190`).

### Target guarantee

For a sandboxed managed run, every accepted daemon data request belongs to one registered wiki and an explicit operation policy.

The child cannot downgrade to the ordinary listener. It cannot open database files directly. It cannot use scoped commands for arbitrary daemon-side filesystem writes.

The assigned wiki is not protected from all bad authorized edits. Keep CAS, version history, validation, and recovery.

An unsandboxed child remains a same-user process. It can reach the ordinary CLI listener or user-readable files. Its capability constrains credentialed requests only.

Do not advertise full cross-wiki confidentiality. Mounted projections, open network access, provider credentials, and user-readable files remain outside this plan's complete protection.

## 4. Architecture decision

### Use a run-lifetime endpoint and capability

Keep `wikid-search.sock` for trusted standalone CLI use. Its current filename and App Group placement are defined in `Sources/WikiDaemonContract/SearchSocketWire.swift:32–44`.

Add short per-run socket names under an App Group-local directory, such as `r/<opaque>.sock`. Validate complete UTF-8 path length before registration.

The current transport limit is 103 path bytes (`Sources/WikiDaemonContract/SearchSocketWire.swift:48–50,70–76`). Do not place long wiki IDs and run IDs together in filenames.

Each listener captures an immutable typed run identity. It still accepts multiple connections during the run. Each connection carries one request and one reply.

The existing transport already uses one request per connection (`Sources/WikiDaemonContract/SearchSocketWire.swift:9–13`). Retain framing, size bounds, deadlines, and same-user checks.

### Why both controls are necessary

A capability limits requests. A distinct endpoint makes run identity mandatory without trusting child-controlled envelope fields.

Seatbelt permits only the assigned run endpoint among daemon endpoints. It denies the ordinary listener and every other run endpoint.

An absent credential cannot select unrestricted mode on a scoped endpoint. A forged run ID cannot change the listener's captured identity.

### Rejected alternatives

**Optional capability on the ordinary listener:** Reject. The child can omit the capability and retain same-user access.

**One connection per run:** Reject. Independent CLI commands need independent connections. A run-lifetime endpoint provides the needed scope.

**Same-user trust only:** Reject for sandboxed managed runs. Keep it only as an explicit standalone and unsandboxed compatibility policy.

**Global mandatory authentication:** Keep as the fallback architecture. Select it if macOS cannot enforce endpoint separation. It requires a separate trusted-human credential workflow.

## 5. Run registration and lifetime

Introduce typed values for run identity, capability, scope, and operation classes. Do not use bare strings internally for these concepts.

The trusted run host generates 256 random capability bits through the system random API. Register the capability before any child can start.

The daemon stores a digest, not the printable secret. Store the run identity, wiki ID, endpoint identity, operation policy, owner lifetime, and expiry.

Do not expose registration, renewal, or scope expansion through the CLI socket. A same-user child must not mint an unrestricted run.

Provide a broker interface to the launcher. Use in-process registration when the daemon hosts the launcher. For separate app hosts, use an authenticated private control channel.

Do not assume the existing XPC channel authenticates the app sufficiently. Audit that channel before exposing registration. Authentication failure must stop the managed launch.

Model registration as a lifecycle: prepared, active, revoked. Make revoke idempotent. Do not persist live capabilities across daemon restart.

Tie the lease to the provider process or managed session, not a single CLI call. Parallel executors receive separate leases. Fallback providers receive replacement leases after the failed provider stops.

For interactive sessions, retain the lease while the provider process can issue tools. Revoke when the session closes, not merely when a generation turn finishes.

On success, error, cancellation, spawn failure, or owner disconnect:

1. Revoke authorization.
2. Stop accepting new scoped connections.
3. Cancel pending work where cancellation is safe.
4. Terminate remaining child processes.
5. Close and unlink the endpoint.
6. Remove scratch according to the existing retention policy.

Use a bounded lease as crash protection. The trusted owner renews it. Never ask the child to renew its own authority.

Define revocation at request admission. A request already admitted can finish unless its operation supports cancellation. Recheck authority before a deferred mutation or job enqueue commits.

Document durable jobs separately. An admitted job can outlive the child, but it must retain the admitted wiki identity. Never re-resolve it from later child input.

## 6. Protocol and validation

Add envelope version 2 with an optional encoded authorization object. The authorization object carries the capability. The listener supplies the authoritative run identity.

Keep authorization absent on ordinary trusted CLI requests. Never interpret absence as unrestricted access on a scoped listener.

Add typed authorization errors:

- `authorizationRequired`
- `authorizationInvalid`
- `authorizationExpired`
- `scopeDenied`

Do not echo credentials in replies. Use generic denial messages that do not reveal other wiki names or existence.

Return authorization errors as domain replies, not transport failures. Map them to CLI exit 1 with a stable error code in diagnostics. Preserve CAS exit 3.

Change dispatcher entry to accept a trusted connection context: ordinary or scoped run. Place validation after version checking and before family execution.

The current insertion point is immediately after `requireCurrentVersion()` (`Sources/wikid/DaemonDomainSocketDispatcher.swift:69–85`).

Decode each operation into a typed request before execution. Use one exhaustive operation-policy table. Unknown operations default to deny for scoped requests.

Require the target wiki to equal the registered wiki. Resolve names only within the assigned wiki. Do not resolve another wiki globally before denying it.

For item-only queue requests, load the item's owning wiki before authorization. Never treat knowledge of an item ID as access.

Check nested targets and batch members. Do not authorize only the envelope's family or the first wiki field.

Ensure search, registry resolution, workload clients, and command clients all use the same connection context. No legacy search frame may bypass scoped authorization.

### Initial operation policy

Define `wikiRead`, `wikiEdit`, and `wikiAcquire` operation classes.

- `wikiRead`: page, source, chat, bookmark, strategy, and workspace reads for the assigned wiki. Include wiki-bound search and job reads.
- `wikiEdit`: approved edits within that wiki. Preserve existing CAS requirements.
- `wikiAcquire`: approved source additions and extraction enqueue for that wiki.

Deny registry create, delete, and rename. Deny global registry enumeration. Return only the assigned descriptor for scoped resolution.

Deny global queue pause, resume, halt, and snapshots. Deny admin maintenance. Deny source refresh initially.

Do not grant all operations in a family because one operation is safe. Add contract tests that classify every family/operation pair.

## 7. Credential delivery

Add a separate secret-bearing launch credential value. Do not put the capability into prompt-rendered `AgentRunContext` fields or generic descriptions.

Deliver the endpoint path and capability through dedicated child environment keys. Add those keys to the provider spawn contract and its tests.

The CLI must not accept the capability as a command-line argument. Arguments can appear in diagnostics and process listings.

Do not place the capability in `WIKI_STATE.md`, staged source files, transcript text, rendered shell commands, or scratch scripts.

Keep the absolute bundled CLI invocation and wiki selector in prompts. The CLI reads credentials at execution time.

This changes the current convenience-only environment contract (`Sources/WikiFSEngine/AgentRunContext.swift:84–90`). Missing credentials now cause a failed command, not unrestricted fallback.

Adapters must preserve credential keys into tool subprocesses. Test every supported adapter's spawn configuration. If an adapter drops them, stop with a clear compatibility error.

Never retry a failed scoped connection on the ordinary endpoint. Removing both keys must not help: Seatbelt must deny the ordinary endpoint.

The child can read and disclose its own capability. Prompt exclusion reduces accidental disclosure, not malicious disclosure. Short lifetime and narrow authority limit the resulting risk.

## 8. Filesystem and profile changes

Edit `Sources/WikiFSCore/Core/SandboxProfile.swift`, not the stale engine path.

### Remove obsolete grants

Remove production `WIKI_DB` and `QUEUE_DB` write rules, sidecar rules, parameters, and launcher arguments.

Those grants currently appear in `generate` (`Sources/WikiFSCore/Core/SandboxProfile.swift:127–169`). Do not remove shared SQLite constants if another sandbox still needs them.

Production edit permission moves into the daemon operation policy. A filesystem read-only profile alone must not imply daemon read-only authority.

### Retain direct-write allowances

Retain scratch and scratch-local temporary writes. Retain required runtime state, Claude temporary paths, and approved package-runner directories.

The current Claude runtime allowances are separate from database access (`Sources/WikiFSCore/Core/SandboxProfile.swift:139–150`). Preserve execution-vector and credential-write denies.

Retain pdf2md restrictions, strict execution rules, device rules, and existing runtime-path tests. Do not broaden global temporary-directory writes.

### Add database and endpoint restrictions

Add a terminal deny section that survives provider-specific layering. Deny child reads and writes to registered wiki databases, central queue databases, registry files, and sidecars.

Prefer denial of the App Group data subtree, with narrow metadata access only where runtime tests prove necessity. Connecting to a socket must not grant general data-directory reads.

Add daemon endpoint connection rules:

1. Deny connections to the ordinary daemon endpoint.
2. Deny connections to all per-run endpoints.
3. Allow connection to the assigned endpoint.

Keep these rules after provider layering. Add terminal data-file denies after generic scratch and runtime allowances.

Use exact canonical endpoint paths. Do not claim that removing file-write grants alone allows or denies `connect` correctly.

First validate macOS Seatbelt local-socket filter syntax with a real listener. Confirm the rule order with actual connects, not profile-string assertions alone.

Retain external API network access. Do not replace the profile with a blanket network deny.

Apply known external-launch and automation pivot denies to managed wiki agents. The strict profile already lists those paths (`Sources/WikiFSCore/Core/SandboxProfile.swift:332–349`).

These denies reduce known escapes. They do not prove complete confinement against all macOS same-user delegation mechanisms. State that residual risk.

### Raw sources

Use staged copies, scoped `source cat`, or the existing mounted projection for source reads. The run context already records staged source paths (`Sources/WikiFSEngine/AgentRunContext.swift:121–125`).

`source cat` returns stored raw bytes or Markdown content (`Sources/WikiCtlCore/SourceCommand.swift:281–296`). It does not require the child to open a database.

Keep immutable originals in the store. A scratch copy may change. A processed-Markdown edit must not change original raw bytes.

Do not equate immutability with indefinite retention. Source lifecycle operations need their own explicit policy.

### Daemon-side file operations

Initially reject `source export` for scoped requests with `scopeDenied`. The existing daemon implementation writes caller-selected paths (`Sources/wikid/DaemonDomainCommands.swift:300–310`).

Do not approve a path with `realpath` and then use an ordinary pathname write. A child can race symlinks between those steps.

For small sources, use scoped `source cat` and let the child write its own scratch file. Seatbelt then enforces the destination.

For large exports, add a bounded download protocol later. The CLI must own final filesystem writes. Do not weaken the current frame cap to avoid this work.

Audit every allowed scoped operation for daemon-side path reads, writes, process launch, and global effects. Deny any unclassified operation.

## 9. Compatibility

Keep normal standalone CLI commands on the ordinary App Group socket. Do not reintroduce launchd registration or direct production database access.

Accept envelope v1 on the ordinary listener during the compatibility window. Reject v1 data operations on scoped listeners with `unsupportedVersion`.

Allow an uncredentialed scoped `hello` response to report required protocol version only. It must expose no wiki data.

The bundled CLI uses v2 for managed runs. If an old daemon lacks scoped registration, stop the launch. Do not silently start an unrestricted child.

Keep output and CAS behavior stable for ordinary commands. New authorization errors need new tests and stable diagnostics.

The fixture-binary split remains separate. A fixture executable must not become a production fallback for missing credentials or a missing daemon.

## 10. Test redesign

### Fixture pattern

Reuse the in-process daemon host already present in the suite. It creates `WikiDaemon`, `DaemonDomainSocketDispatcher`, and `DaemonSearchSocketServer` (`Tests/WikiFSAppTests/AgentSandboxProcessTests.swift:91–108`).

Extend the fixture to register a run for wiki A and hold its endpoint, capability, and lease. Start the daemon before every daemon-dependent test.

Stop listeners before deleting the fixture container. The existing cleanup order already does this (`Tests/WikiFSAppTests/AgentSandboxProcessTests.swift:110–119`).

Use the production CLI for scope tests. Do not substitute the fixture binary or direct store calls for the attempted operation.

Use parent-side store reads to verify effects. These reads verify results and do not grant the child database access.

### Required matrix

| Case | Expected result |
| --- | --- |
| Scoped sandbox, valid capability, wiki A read | Successful domain reply |
| Scoped sandbox, valid capability, wiki A CAS edit | Success, one new version |
| Same endpoint and capability, wiki B edit | Typed `scopeDenied`, unchanged B history |
| Same scope, wiki B read or search | Typed `scopeDenied`, no B content |
| Missing or malformed capability | Typed authorization error |
| Expired or revoked capability on an accepted connection | Typed authorization error |
| Cross-run capability on another endpoint | Typed authorization error |
| Credential keys removed, ordinary endpoint attempted | Kernel connection denial, no fallback |
| Custom frame sent without bundled CLI | Same scope checks |
| v1 data request to scoped endpoint | Typed `unsupportedVersion` |
| Direct A/B/queue DB read and write, including sidecars | Kernel denial |
| Scratch file transform, POSIX heredoc, zsh temporary path | Success |
| Host-file write outside allowances | Kernel denial |
| Scoped source export to host path or symlink | Typed `scopeDenied`, unchanged sentinel |
| Source Markdown edit | Raw-byte digest unchanged, history appended |
| Global queue control or registry mutation | Typed `scopeDenied` |
| Queue item belonging to B | Typed `scopeDenied` |
| Cancellation, spawn error, provider fallback | Lease revoked and endpoint removed |
| Two concurrent runs | No credential or wiki crossover |
| Unsandboxed use of ordinary listener | Documented same-user behavior, not an isolation test |

For cross-wiki tests, first complete a successful scoped A read. Then attempt the B command through the same live endpoint.

Assert the typed domain error. Explicitly reject daemon-not-running, permission-denied transport, timeout, and malformed-reply outcomes as false evidence.

### Existing tests

Transform `productionSandboxPreventsCrossWikiMutation` into a daemon authorization test. Its current missing-daemon path appears at `Tests/WikiFSAppTests/AgentSandboxProcessTests.swift:599–630`.

Transform `absoluteWikictlInvocationWorksWithoutAgentEnvironment` into a scoped absolute-invocation test. Remove convenience variables, but preserve credentials (`Tests/WikiFSAppTests/AgentSandboxProcessTests.swift:546–593`).

Replace `writeProfileAllowsCentralQueueSQLiteInsert` with direct queue database denial plus successful scoped enqueue. Replace the no-allowance test with the unified direct-access denial matrix (`Tests/WikiFSAppTests/AgentSandboxProcessTests.swift:313–382`).

Retain shell, scratch, strict-execution, runtime-state, and package-runner tests. They test a separate boundary.

Add exhaustive unit tests for operation classification, target extraction, protocol versions, redaction, and lease state transitions.

Use Swift Testing. Keep subprocess waits nonblocking and timeout-bounded. Do not use sleeps to prove listener readiness.

## 11. Implementation phases and rollout

### Phase 0: correct the evidence

Status: IMPLEMENTED (`da3b8b74`). `productionSandboxPreventsCrossWikiMutation` became `crossWikiMutationReachesDaemonWithoutAuthorization`: the fixture daemon starts, the wiki-A-sandboxed child's `source edit-markdown` genuinely reaches it, and the test asserts the cross-wiki write SUCCEEDS (new wiki B head, history 1→2, raw bytes untouched) — the migration regression recorded, not faked. No known-issue annotation: the test is an accurate characterization, and a green run states "the gap is present," never "the fence holds." Phases 2–3 flip this assertion to a typed `scopeDenied`.

Land an accurate test description with the migration stack. Start the fixture daemon where transport success is required.

Replace the old cross-wiki claim with a test that records the current missing authorization boundary. Do not preserve a false green test.

Use a temporary known-issue annotation only if the stack cannot land the scope repair together. Track it explicitly and remove it in Phase 3.

### Phase 1: protocol and authorization core

Status: IMPLEMENTED (`2ece6a4b`). Envelope v2 with the optional authorization object; v1 stays served on the ordinary listener through the compatibility window; typed errors `authorizationRequired` / `authorizationInvalid` / `authorizationExpired` / `scopeDenied`; `DaemonRunRegistry` (actor) with typed run identity/capability/digest/scope/classes, prepared→active→revoked, idempotent revoke, owner-renewed bounded lease, `SecRandomCopyBytes` capability, digest-only storage, nothing persisted; dispatcher `handle(_:context:)` with the exhaustive `DaemonScopedOperationPolicy` table; scoped `source export` and `source refresh` denied. Scoped production launches remain disabled — exercised by `DaemonRunRegistryTests`, `DaemonScopePolicyContractTests` (source-parsed exhaustiveness), and `DaemonScopedSocketTests` over the real socket + dispatcher with a context-stamped handler standing in for the Phase 2 listener.

Deviations from the letter of the plan (all conservative):

- A REVOKED lease answers `authorizationExpired` (the lease is over), and a PREPARED (registered, never activated) lease answers `authorizationInvalid` (not yet valid). Both replies use the one fixed generic message, so lease state does not leak.
- A CREDENTIALED scoped `hello` still passes authorization and receives the full capabilities answer; only the UNcredentialed hello is version-only, per §9. Malformed credentials on hello are `authorizationInvalid`.
- Scoped `wiki resolveWiki` with a foreign selector answers the fixed `scopeDenied` text (no wiki name, no existence signal); the assigned wiki resolves by id or its own display name.
- The policy table classifies the OKF `status`/`freshness`/`verify`/`correct` operations as `wikiEdit` (they mutate), not reads; only `okfInspect` and the explicit reads are `wikiRead`.

Add unit tests for all family routes, queue ownership, malformed requests, and revocation. Deny scoped export before exposing scoped listeners.

### Phase 2: endpoint and profile gate

Add run-lifetime listeners and the trusted registration broker. Add live macOS endpoint-denial tests.

Prove ordinary-listener denial with credentials removed. Prove other-run endpoint denial. If either fails, stop and choose global mandatory authentication.

Add direct database denial and known process-pivot denial tests. Preserve adapter runtime compatibility tests.

### Phase 3: managed-run integration

Wire registration before spawn and revocation through all teardown paths. Add credential propagation to supported adapters.

Enable the new profile and daemon scope together. Never enable token-only managed runs against the unrestricted listener.

Complete the live process matrix. Remove the obsolete database and queue grants only after successful daemon operations pass.

### Phase 4: documentation and release checks

Update `plans/sandbox-agent.md`, `plans/cli-domain-commands.md`, and the `PLAN.md` index. Add a conforming progress entry.

Explain the regression, restored guarantees, unsandboxed limit, adapter credential contract, and scoped-export restriction.

### Stacked branch order

Build on migration PR #1463 and the fixture-binary split after their target boundaries stabilize. Do not mix fixture-target extraction with authorization behavior changes.

Rebase this work after both stacks land. Update file references and confirm no fixture fallback reaches production data.

Migrate daemon-dependent tests before removing direct-database allowances. Ship the listener, authorization, credential delivery, and fallback denial as one enforcement change.

Keep macOS as the required platform. Keep sockets App Group-local. Keep daemon lifetime tied to the application. Do not return to launchd.

## 12. Verification and exit criteria

Run on supported macOS:

- `make build`
- `make test`
- Targeted sandbox, daemon socket, run-context, and CLI routing suites.
- Bare `swift build` and targeted `swift test` after prerequisites are synchronized.
- A packaged-app smoke test with two disposable wikis and a real managed child.

The smoke test must prove allowed A edits, typed B rejection, missing-daemon guidance, cancellation revocation, and no direct database access.

A test that fails to connect does not prove wiki authorization. A test that uses only a fake dispatcher does not prove Seatbelt endpoint separation.

Do not claim success until the custom-client downgrade tests pass. Record the exact macOS version and binaries used.

## 13. Resolved decisions

All five approved as recommended by the operator, 2026-10-22:

1. **Approved.** Unsandboxed managed runs retain the documented same-user risk. Full authentication for every CLI request is a separate trusted-credential project, not part of this plan.
2. **Approved.** Complete mounted-file (read) confidentiality remains outside this plan; the plan restores the write boundary and scoped daemon access only.
3. **Approved.** Scoped `source export` is denied (`scopeDenied`) until a bounded download protocol exists; scoped agents use `source cat` plus child-side scratch writes in the interim.
4. **Approved.** `source refresh`, admin maintenance, and registry/queue-global operations are denied in the initial scoped policy; each returns only through an explicit future approval.
5. **Approved.** If local-socket Seatbelt separation fails its runtime gate (Phase 2), fall back to global mandatory authentication. Do not ship a token-only substitute.

# ACP adapter vendoring (issue #1257 Level 2)

Date: 2026-09-15. Level 1 (canonicalize `npx` / `npm exec` / `bunx` / `bun x`
launches through the login-shell-resolved bun) merged as `871328c9` (PR
#1258). This doc covers Level 2: the Claude ACP adapter ships as a vendored,
digest-pinned bundle inside the app, and adapter-shaped provider launches run
it through the resolved bun.

## Goal

A default Claude ACP launch (`bun x @agentclientprotocol/claude-agent-acp`)
used to run a package runner that wrote caches into `$HOME` (`~/.npm`,
`~/.bun`) — EPERM'd under the agent sandbox on the first chat. Level 1 moved
the runner to the resolved bun. Level 2 removes the package runner from the
launch entirely:

```
configured:  bun x @agentclientprotocol/claude-agent-acp [args…]
level 1:     <resolved-bun> x @agentclientprotocol/claude-agent-acp [args…]
level 2:     <resolved-bun> run <App.app>/Contents/Helpers/claude-acp-adapter.js [args…]
```

The rewritten command matches no package-runner token in
`ACPBackend.providerHomeSubpaths`, so the sandbox layers no `~/.npm` /
`~/.bun` write allowance — reads stay open through the base profile, and the
bundle needs nothing else. The adapter itself also runs under bun now
(`bun run <file>` ignores the shebang), which closes the Level 1
"adapter execs Node via its own shebang" follow-up for this path.

Three properties follow from shipping the bundle:

1. **Zero home-cache writes** by the launch shape (AC.3; the only automated
   coverage of the fresh-machine posture — see the coverage-gap note below).
2. **One reviewed place pins the adapter version** — a single variable in
   `scripts/sync-acp-adapter.sh` generates every other record.
3. **The ACP protocol version becomes a release contract.** The vendored
   version speaks ACP protocol version 1 (`initialize` in `ACPBackend`);
   adapter bumps are app releases, reviewed through the gate.

## Files

| Path | Role | Hand-edited? |
| --- | --- | --- |
| `scripts/sync-acp-adapter.sh` | The generator + gate. Holds `ADAPTER_VERSION` + the dist identity constants — the only hand-edited version source anywhere. | version variables only |
| `tools/claude-acp-adapter/package.json` | Vendor pin; dependency written by the sync script. | never (generated) |
| `tools/claude-acp-adapter/bun.lock` | The installed-bytes contract (`bun install --frozen-lockfile`). | never |
| `tools/claude-acp-adapter/build.mjs` | `bun install` + `bun build --target=bun` → the bundle. | build logic only |
| `tools/claude-acp-adapter/verify.mjs` | ACP `initialize` handshake against the bundle (AC.6). | build logic only |
| `tools/claude-acp-adapter/adapter.lock.json` | The authoritative provenance record (generated). | never (generated) |
| `Sources/WikiFSEngine/VendoredAdapterPin.swift` | The compile-time pin (generated; consumed by `ACPBackend` + the app launch check). | never (generated) |
| `Resources/claude-acp-adapter.bundle.js` | The reviewed artifact `build.sh` stages into `Contents/Helpers`. | never (generated) |
| `Makefile` | `acp-adapter` gate on `check`/`build`/`release`/`check-release`/`test`; `acp-adapter-sync` target. | targets |
| `build.sh` | Stages the bundle into `Contents/Helpers` + `build/`, signs it. | staging block |

## Provenance record (verified 2026-09-14)

- Package: `@agentclientprotocol/claude-agent-acp` **0.77.0**
- Upstream: `agentclientprotocol/claude-agent-acp` (GitHub), reviewed release
  commit `dfe823b9581979cd22db40272d4469cc7e42b77e` ("release 0.77.0")
- Tarball: `https://registry.npmjs.org/@agentclientprotocol/claude-agent-acp/-/claude-agent-acp-0.77.0.tgz`
- dist.integrity (SHA-512): `sha512-m8mhsAOc5+m/QZNsKCrfyIRv4KQrCLqSYHZP/aUvL3X0Xn0f9n4wKKNpOpOv0Kblh/2Mkpd4SW0KypN1dZkJfg==`
- dist.shasum (legacy SHA-1): `ca57cfccd59a0057c6f81f4bde5dfbd90479950d`
- Entry point (the package's `bin`): `dist/index.js`
- ACP protocol version spoken: **1** (matches `ACPBackend`'s `initialize`)
- Bundle: single-file `bun build --target=bun`, 146 modules, byte-identical
  when rebuilt from the same repo-relative directory (bun embeds input paths
  as comments — same fixed-dir discipline as `scripts/sync-extractor-packages.sh`).
  The bundle is **not** minified, and its bytes are committed exactly as bun
  emitted them (a few whitespace-only blank lines and all — deliberate: the
  digest pins the bundler's canonical output, and no repo gate runs
  `git diff --check`).

## Reproduction recipe

```sh
cd tools/claude-acp-adapter
bun install --frozen-lockfile   # reproduce node_modules from the committed bun.lock
bun build.mjs                   # bun build --target=bun → ../../Resources/claude-acp-adapter.bundle.js
bun verify.mjs                  # spawn <bun> run <bundle>, complete an ACP initialize handshake
```

`bun.lock` pins the installed bytes; `adapter.lock.json` records the sha256 of
`package.json`, `bun.lock`, and the committed bundle, plus the npm dist
metadata above.

## Gate and bump procedure

`make acp-adapter` runs `scripts/sync-acp-adapter.sh --check` (no network, no
bun) in two layers. First it re-derives every generated value from the
script's constants and compares against the tree — including the dist
identity, compared EXACTLY against the `ADAPTER_DIST_INTEGRITY` /
`ADAPTER_DIST_SHASUM` constants. Then it re-renders all three generated
records with the same writer code and byte-compares them with the committed
files, so ANY hand edit (an extra key, a changed comment, formatting drift)
fails even where a value check would pass. It is a prerequisite of `check`,
`build`, `release`, `check-release`, and `test` — the same targets
`extractor-packages` gates. The gate deliberately does NOT regenerate; a
stale tree must be re-synced and reviewed, not silently rebuilt.

Adapter bump:

1. Change `ADAPTER_VERSION` and fill `ADAPTER_DIST_INTEGRITY` /
   `ADAPTER_DIST_SHASUM` (`npm view <pkg>@<version> dist.integrity
   dist.shasum`) in `scripts/sync-acp-adapter.sh`.
2. `make acp-adapter-sync` — rewrites `package.json`, the Swift pin,
   `bun.lock` (plain `bun install`, since the pin changed), the bundle, and
   `adapter.lock.json`. When the registry is reachable, sync cross-checks
   the constants against the live packument and hard-errors on a mismatch
   (a mis-copied constant, or a registry-side surprise for the same
   version); a bump with an unreachable registry is a hard error.
3. Review the generated diff (lock JSON, package.json, Swift pin, bundle).
4. Run the gates; `tools/claude-acp-adapter/verify.mjs` re-proves the
   handshake.
5. Ship in the app release. The pinned ACP protocol version is the
   compatibility contract.

Never hand-edit a generated record — the gate fails by design, and
`AdapterVendoringLockTests` re-checks the records from Swift (including the
dist fields against the script's constants).

## Launch rewrite (ACPBackend)

`startProcess` composes, for adapter-shaped launches only:

1. **Shape gate** — `isJSAdapterLaunch`; anything else never pays for the
   bun locate.
2. **`effectiveAdapterSpawn`** (pure, unit-tested): Level 1
   `canonicalizedSpawn` → Level 2 `vendoredAdapterRewrite` → configured
   fallback.
3. **Staleness re-probe** — unchanged: the composed launch still carries
   `usedCanonicalBun` + `bunResolutionUsed`, so a bun swapped between locate
   and exec falls back to the configured command.

`vendoredAdapterRewrite` matches only `["x", spec, adapterArgs…]` where spec
is the vendored package bare or pinned at EXACTLY
`VendoredAdapterPin.vendoredAdapterPinnedVersion`. Any other version keeps
the Level 1 launch — the user asked for a version the vendored bundle is not.
The bundle path comes from the injectable `vendoredBundlePath` seam
(default `HelpersLocation.bundledHelperPath("claude-acp-adapter.js")`); nil
keeps the Level 1 result. `launchHint` keeps working (the bundle name
contains "claude").

`WikiFSApp`'s startup launch check now warns when the vendored adapter is
missing (it used to warn about `bun`, which is mise-managed and never
packaged — it fired on every healthy install).

## Non-goals (deliberate)

- **`@agentclientprotocol/codex-acp` is not vendored.** It stays at its
  existing `npx …@1.1.7` pin in `AgentProviderModelCache`. Vendoring it is a
  follow-up applying this same recipe.
- **`ACPProviderModelProbe` is not wired with the rewrite** — it has its own
  spawn path (issue #1276 seam) and never went through Level 1 either;
  unchanged behavior is preserved. Noted as a follow-up.
- **Settings free-form stays the escape hatch.** The default provider command
  remains `bun x @agentclientprotocol/claude-agent-acp`; the rewrite happens
  at launch, so existing and fresh configs upgrade without migration. A user
  pinning a different version gets that version.
- **End-to-end fresh-machine coverage gap (accepted):** no automated
  provider/UI harness exists for a full chat turn, so the zero-home-write
  property is pinned by `vendoredCommandLayersNoHomeSubpaths` (the sandbox
  plan for the rewritten command) and validated manually
  (`FreshMachineVendoredClaudeACPScenario`: scratch account with only bun in
  the login-shell PATH; run one Ingest + one chat; assert `~/.npm` /
  `~/.bun` were not created and the run log shows the vendored launch line).

## Test coverage map

| Criterion | Test |
| --- | --- |
| AC.1 gate | `make -n <target>` shows the `acp-adapter` prereq (all five targets); `--check` executed in fresh / tampered / stale / disagreeing states |
| AC.1 records | `AdapterVendoringLockTests` (lock ↔ pin ↔ package.json ↔ digests on disk) |
| AC.2 rewrite | `vendoredAdapterRewriteRewritesMatchingSpec`, `vendoredAdapterRewriteAcceptsMatchingPinnedVersionOnly`, `vendoredAdapterRewriteNilBundleKeepsCanonical` |
| AC.2 composition | `effectiveAdapterSpawnComposesCanonicalThenVendored`, `effectiveAdapterSpawnFallsBackWhenBunUnresolved`, `unresolvedBunSkipsVendoredRewrite` |
| AC.3 sandbox | `vendoredCommandLayersNoHomeSubpaths` (no `/.npm` / `/.bun` in the wrapped profile) |
| AC.4 fallbacks | existing Level 1 suite unchanged + the nil-path tests above |
| AC.5 bundling | `HelpersLocationTests` (seam-injected priority/executability/dev-build) + `make build` + `codesign -dv` |
| AC.6 handshake | `tools/claude-acp-adapter/verify.mjs` (build-tool check, not `swift test`) |

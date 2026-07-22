# Plan: Keychain Sharing between the selfdrivingwiki app and `wikid`

**Status:** IMPLEMENTING (this branch). Unblocks daemon Phase B / Phase C — ACP backends.
**Scope:** Enable `wikid` to read the agent API keys the app wrote to the
Keychain. Infrastructure prerequisite, the #1 real-world snag risk for the
daemon migration.
**Last updated:** 2026-07-22

---

## TL;DR (recommended path)

Two changes, one portal step:

1. **Migrate `KeychainSecretStore` to the DataProtection keychain with an
   explicit shared access group** — add `kSecUseDataProtectionKeychain: true`
   and `kSecAttrAccessGroup: "<TEAM_ID>.<suffix>"` to every query, where the
   group is **derived per-developer from `signing/local.config`** (never
   hardcoded to one developer's slug).
2. **Add `keychain-access-groups` to the entitlements of BOTH the app and the
   daemon**, **generated at build time** from the per-developer config (the app
   entitlements are already generated this way; the daemon entitlements are now
   generated too — the previously-committed static `signing/wikid.entitlements`
   is deleted, since a committed file baked to one developer's group would break
   for anyone else).
3. *(Portal, human-only)* The provisioning profiles already authorize the
   `<TEAM_ID>.*` keychain wildcard, so **no new profile is strictly required**.
   **R1 spike PASSED**: the operator verified the daemon launches fine with
   `keychain-access-groups`.

> Why not "do nothing, the file keychain already shares"? See §2 (Alternatives)
> — the file keychain *may* work for two same-user non-sandboxed processes today,
> but it is fragile (TCC, sync, Keychain Access.app ACL edits), unproven for the
> daemon, and breaks the moment either target gains a sandbox. The
> DataProtection keychain + access group is the Apple-blessed, future-proof
> mechanism.

> **Per-developer resolution (the load-bearing invariant):** the access group is
> NEVER hardcoded to one developer's slug. It is derived from
> `signing/local.config` (`TEAM_ID` + `APP_GROUP`, the latter with its `group.`
> prefix stripped), with an optional explicit `KEYCHAIN_ACCESS_GROUP` override.
> `build.sh`, the Makefile, and `tools/keychaingen` all use the **same formula**,
> so app entitlements, daemon entitlements, and the Swift constant agree for ANY
> developer who clones + runs `signing/setup.sh`. This mirrors how `APP_GROUP`
> and `BUNDLE_ID` are handled (PR #20).

---

## 1. Current Keychain access path (as found)

### 1.1 The store

`KeychainACPCredentialStore` (`Sources/WikiFSCore/Integrations/ACPCredentialStore.swift:55-92`)
is a thin wrapper around a shared helper:

- **Service:** `org.sockpuppet.WikiFS.acp` (`:56`)
- **Legacy account:** `acp-agent-api-key` (`:57`)
- **Per-provider account (#324):** `acp-provider:<id>` (`:89-91`)
- Class: `kSecClassGenericPassword` (generic-password item).

All reads/writes delegate to `KeychainSecretStore`
(`Sources/WikiFSCore/Core/KeychainSecretStore.swift:16-73`), which built plain
`SecItem*` queries with `kSecClass`/`kSecAttrService`/`kSecAttrAccount` only —
**no** `kSecUseDataProtectionKeychain` and **no** `kSecAttrAccessGroup`. So
items lived in the **file-based ("login") keychain**, un-grouped.

The other two conformers (`KeychainExtractionCredentialStore` service
`org.sockpuppet.WikiFS.extraction`, `KeychainZoteroCredentialStore` service
`org.sockpuppet.WikiFS.zotero`) share the same helper, so all three migrate
together. The **FileProvider extension does NOT touch the Keychain** (verified:
no `SecItem`/`Credential` references in `Sources/WikiFSFileProvider/`), so it is
left out of the keychain-access-groups entitlement (adding it would risk AMFI
killing the sandboxed extension if its profile lacks the capability).

### 1.2 How the key reaches the ACP backend

`AgentBackendFactory.providerHints(...)` stuffs the resolved API key into
`hints[.acpAgentApiKey]`, which `ACPBackend` injects as the spawn's auth. The
key is read from the Keychain by the caller — the app's ingest/chat path today,
and — once Phases B/C land — the daemon's workload path (the daemon links
`WikiFSEngine`, whose `ExtractionCoordinator` defaults to
`KeychainACPCredentialStore()`).

### 1.3 Daemon context

- `wikid` is a **LaunchAgent** registered via `SMAppService.agent(plistName:)`,
  bundled at `Contents/Helpers/wikid` inside the app.
- It runs as the **same Unix user** as the app (LaunchAgent in the user domain).
- It is **NOT sandboxed** (no `com.apple.security.app-sandbox`).
- **Production signing (`build.sh`) signed `wikid` with NO entitlements**, while
  dev signing (`Makefile install-daemon`) applied a committed
  `signing/wikid.entitlements`. That committed file was baked to ONE developer's
  App Group (`group.com.willsargent.wiki`), so it only worked for them — this
  branch deletes it and generates the daemon entitlements per-developer (§3.4).

---

## 2. Sharing-mechanism — chosen: shared keychain-access-group + DataProtection keychain

Add the same `keychain-access-groups` entitlement to both the app and the daemon,
tag items with `kSecAttrAccessGroup`, and move items onto the DataProtection
keychain (`kSecUseDataProtectionKeychain: true`). Apple-blessed; works across
sandbox/unsandboxed; survives Keychain Access.app edits and iCloud Keychain; the
provisioning profiles already authorize the `<TEAM_ID>.*` wildcard, so this is
mostly a code + entitlements change. (Alternatives — shared `.keychain` file, or
XPC delegation — were rejected; see the original draft for rationale.)

---

## 3. Provisioning & build changes (implemented here)

### 3.1 Access group string — derived per-developer

`<TEAM_ID>.<suffix>` — the team prefix is mandatory for `keychain-access-groups`.
The suffix is the App Group with its leading `group.` stripped (so
`APP_GROUP="group.com.example.wiki"` → suffix `com.example.wiki`). An explicit
`KEYCHAIN_ACCESS_GROUP` in `signing/local.config` overrides the derived value.
The derivation is the SAME in three places, so app, daemon, and the Swift
constant always agree:

| Producer | Where | Expression |
|---|---|---|
| Swift constant | `tools/keychaingen/main.swift` | explicit `KEYCHAIN_ACCESS_GROUP` ‖ else `${TEAM_ID}.${APP_GROUP#group.}` |
| App + daemon entitlements | `build.sh` heredocs | `KEYCHAIN_ACCESS_GROUP="${KEYCHAIN_ACCESS_GROUP:-${TEAM_ID}.${APP_GROUP#group.}}"` |
| Makefile dev path | `Makefile` | `$(or $(call cfg,KEYCHAIN_ACCESS_GROUP),$(TEAM_ID).$(patsubst group.%,%,$(APP_GROUP)))` |

`signing/local.config` is gitignored, per-developer; `signing/setup.sh` writes
`TEAM_ID` + `APP_GROUP`, so the group tracks every developer's real account
with **zero per-user values in committed source** (matching the codebase
convention for `APP_GROUP`/`BUNDLE_ID`). `signing/local.config.example`
documents the optional override.

### 3.2 How the code resolves the group — compile-time, per-developer

The directive requires a **compile-time constant** (the daemon is a bundled
helper; we did not want to rely on `Bundle.main` at runtime). We follow the
existing **`GeneratedVersion.swift` codegen pattern** exactly:

- New generator `tools/keychaingen/main.swift` reads `signing/local.config`
  (`KEYCHAIN_ACCESS_GROUP`, else `TEAM_ID` + `APP_GROUP`), and writes the
  gitignored `Sources/WikiFSCore/GeneratedKeychain.swift`
  with `public static let accessGroup = "…"` (empty when `signing/local.config`
  is absent — fresh clones / CI / tests → "no group" → legacy file-keychain
  behavior preserved).
- A new `make keychain` target (mirroring `make version` / `make prompts`) is a
  prerequisite of `build`/`check`/`test`/…; CI runs `make version prompts keychain`.
- Both the app and the daemon get the constant by linking `WikiFSCore` — no
  Info.plist lookup, no `Bundle.main` dependency.

### 3.3 App entitlements — `build/WikiFS.entitlements` (generated by `build.sh`)

Added to the `APP_ENTITLEMENTS` heredoc in `build.sh`:

```xml
<key>keychain-access-groups</key>
<array>
    <string>${KEYCHAIN_ACCESS_GROUP}</string>
</array>
```

### 3.4 Daemon entitlements — generated per-developer (committed static DELETED)

The daemon is a bare Mach-O with no Info.plist, so its entitlements can't ride
the app's Info.plist. Previously a committed `signing/wikid.entitlements` held
them — but that file was baked to one developer's App Group + access-group
suffix, so it would break for anyone else (`errSecMissingEntitlement` / AMFI
kill at exec, or a nil key).

**Fix (PR #20 pattern — "remove committed .entitlements, generate at build
time"):** `build.sh` now generates `${WIKID_ENTITLEMENTS}` (`build/wikid.entitlements`,
next to `build/WikiFS.entitlements`) from a heredoc using the per-developer
`${APP_GROUP}` and `${KEYCHAIN_ACCESS_GROUP}`, and signs `wikid` with
`--entitlements "${WIKID_ENTITLEMENTS}"`. The Makfile dev path
(`make install-daemon`) generates the same file inline. The committed
`signing/wikid.entitlements` is **deleted**. The generated content carries:

```xml
<key>com.apple.security.application-groups</key>
<array><string>${APP_GROUP}</string></array>
<key>keychain-access-groups</key>
<array><string>${KEYCHAIN_ACCESS_GROUP}</string></array>
```

(For the operator's machine this resolves to the exact value the R1 spike
verified, so that result still holds — same entitlement lands on the binary.)

### 3.5 FileProvider / wikictl

No change. The FileProvider extension does not access the Keychain (§1.1); it
is NOT given `keychain-access-groups` (adding it would risk AMFI killing the
sandboxed extension if its profile lacks the capability). `wikictl` neither
spawns ACP agents nor reads API keys.

---

## 4. Code changes

### 4.1 `KeychainSecretStore` — access group + DataProtection keychain

`Sources/WikiFSCore/Core/KeychainSecretStore.swift`:

- `accessGroup = GeneratedKeychain.accessGroup` (compile-time, "" when unconfigured).
- `useDataProtectionKeychain = !accessGroup.isEmpty`.
- A shared internal `baseQuery(service:account:useDP:accessGroup:)` now builds
  the class/service/account dict and **conditionally** adds
  `kSecUseDataProtectionKeychain: true` (when `useDP`) and
  `kSecAttrAccessGroup: <group>` (when non-empty) — so every read / delete /
  update / add query carries both keys in production, and neither in tests.
- Public `read(service:account:)` / `write(service:account:value:error:)` route
  to internal `read/write(… useDP:accessGroup:)` using the resolved group. The
  three `Keychain*CredentialStore` conformers are unchanged (same public API).

### 4.2 Daemon-side access group resolution

Handled by the compile-time constant (§3.2). No daemon Swift change is needed
for the access group — the daemon links `WikiFSCore`, which carries
`GeneratedKeychain.accessGroup`. The daemon's entitlement (§3.4) authorizes the
group; build.sh applies it.

### 4.3 Migration of existing keys (file → DataProtection keychain)

Moving to `kSecUseDataProtectionKeychain: true` changes the keychain an item lives
in, so existing file-keychain keys become invisible. `KeychainSecretStore
.migrateLegacyItemsToDataProtection()` (called once from the app's launch path,
mirroring `DatabaseLocation.migrateFromApplicationSupportIfNeeded()`) does a
one-shot, idempotent copy:

- Guard: no-op when `accessGroup` is empty (tests / fresh clones / unconfigured).
- Enumerate all legacy file-keychain generic-password items whose service has the
  `org.sockpuppet.WikiFS.` prefix (catches ACP legacy + per-provider, Extraction,
  Zotero — all three stores), copy each to the DataProtection keychain under the
  shared access group, then delete the legacy original. Best-effort: a failed DP
  write leaves the legacy item in place (never loses a key); failures are
  surfaced via `DebugLog.config`, never thrown.

The daemon does NOT migrate (it is a reader); it relies on the app having
migrated, or on the user re-entering the key (which writes straight to the DP
keychain — no migration needed).

---

## 5. Testing approach

### 5.1 Unit tests (`Tests/WikiFSTests/KeychainSecretStoreTests.swift`, automated)

- `baseQuery(useDP:true, accessGroup:"G")` includes `kSecUseDataProtectionKeychain`
  and `kSecAttrAccessGroup="G"`; `baseQuery(useDP:false, accessGroup:"")` omits
  both (legacy shape). Deterministic, non-polluting — tests the core requirement
  without hitting the real Keychain.
- `migrateLegacyItemsToDataProtection()` is a safe no-op when `accessGroup` is
  empty (the test-runner path) — smoke test it does not throw.

### 5.2 Integration test (manual — the real gate)

Documented as a runbook, because it needs a real signed build:

1. `make build` (real signing) so both the app and `wikid` carry the
   `keychain-access-groups` entitlement.
2. Launch the app, enter an ACP API key, confirm it writes.
3. `security find-generic-password -s "org.sockpuppet.WikiFS.acp" -a "acp-provider:<id>" -g`
   — confirm the item now has an `agrp` matching `<TEAM_ID>.<APP_GROUP-suffix>`
   (the value `make keychain` / `build.sh` derived from your `signing/local.config`).
4. Start the daemon, trigger an ACP workload, confirm the daemon does NOT
   re-prompt and the ACP agent spawns (auth works).
5. Negative control: rebuild with the daemon entitlement removed → the daemon
   gets `errSecMissingEntitlement`/nil key (proves the entitlement is load-bearing).
6. `codesign -d --entitlements - "build/…/wikid" | grep -A2 keychain-access-groups`
   catches the §3.4 regression at build time.

> Caveat: the DataProtection keychain + access groups does not round-trip in
> `swift test` (no entitlements / access group on the test runner). Only §5.1
> is automated; the access-group + migration behavior is validated by §5.2.

---

## 6. Risks

| # | Risk | Status / Mitigation |
|---|------|---------------------|
| R1 | Daemon entitlement provisioning (AMFI SIGKILL at exec). | **SPIKE PASSED** — operator verified the daemon launches with `keychain-access-groups`. |
| R2 | Existing keys become invisible (file → DP). | §4.3 migration handles it; else a one-time re-prompt. |
| R3 | Portal "Keychain Sharing" capability on the App ID. | The `<TEAM_ID>.*` wildcard in the profile satisfies it (R1 passed). Optional explicit capability if a future build fails. |
| R4 | TCC prompts. | Reduced — access-group reads don't trigger "another app's data" prompts. |
| R6 | Wrong/empty group silently disables sharing. | Compile-time codegen + identical formula in build.sh/codesign; `DebugLog.config` events. |

---

## 7. Implementation order (this branch)

1. Codegen `tools/keychaingen/main.swift` + `make keychain` prereq + `.gitignore`.
2. `KeychainSecretStore` refactor (access group + DP keychain + migration).
3. `build.sh` (APP_ENTITLEMENTS `keychain-access-groups` + wikid `--entitlements`).
4. App launch-path migration call.
5. Unit tests (§5.1) + manual integration runbook (§5.2).
6. `swift build` + `swift test` green.

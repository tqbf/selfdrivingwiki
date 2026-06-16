# Signing & provisioning (the Apple incantations)

Everything needed to get the **App Group** + **File Provider extension**
working on this Mac, for **local-only** use. Needed starting in Phase 2 of
`plans/BRINGUP.md`; Phases 0–1 run fine on ad-hoc signing.

## Ground truth (this machine, 2026-06-15)

- Codesigning identities installed: **none** (`security find-identity -v -p
  codesigning` → 0 valid). Must install an Apple Development cert.
- Apple Developer membership: **paid** (Developer ID + team in the `Makefile`).
  So we use the paid team — *not* a free/personal team (which can't do App
  Groups).
- Team ID: **`KK7E9G89GW`**.
- This Mac's **Provisioning UDID: `00006050-00190839016B401C`** (Apple M5 Pro).
- **No** Developer ID / notarization needed — that's distribution-only.

## What we're NOT doing

- Not notarizing, not using Developer ID for local runs.
- Not using a free/personal team (can't do App Groups).
- Not replacing File Provider with a plain-folder export — File Provider is a
  core POC goal of this project. See [[wikifs-fileprovider-poc-goal]].
- **Provisioning approach: MANUAL PORTAL** (decided 2026-06-15). No throwaway
  Xcode project; profiles are downloaded by hand and embedded by `build.sh`.

## Identifiers (locked)

| Thing | Value |
| --- | --- |
| App bundle id | `org.sockpuppet.WikiFS` |
| Extension bundle id | `org.sockpuppet.WikiFS.FileProvider` |
| App Group id | `group.org.sockpuppet.wiki` |
| SQLite DB path | `~/Library/Group Containers/group.org.sockpuppet.wiki/WikiFS.sqlite` |
| File Provider mount | `~/Library/CloudStorage/WikiFS` (assigned by macOS) |

> Note: `INITIAL.md` §3 wrote the DB path as `<team-id>.wikifs` — that's the
> wrong format. Modern App Group ids must start with `group.`, and the group
> container dir is named by the full group id. Use the path above.
>
> Also note the group is `group.org.sockpuppet.wiki` (not `…wikifs`). The
> originally-planned `…wikifs` group got fouled up in the portal, so the
> working group/profiles use `…wiki`. The profiles in `signing/` authorize
> exactly this — verified 2026-06-15 (see below). Don't "fix" the name without
> regenerating both profiles.

## Verified state (2026-06-15) — steps 1–5 DONE ✅

Confirmed by decoding the profiles in `signing/` (`security cms -D`):

- **Cert installed:** `Apple Development: Thomas Ptacek (7F2QE7P59D)` — matches
  `DEV_IDENTITY` in the `Makefile` already (no change needed).
- **Device registered:** this Mac (`00006050-00190839016B401C`) is in both
  profiles' `ProvisionedDevices`.
- **Both profiles:** team `KK7E9G89GW`, platform macOS, **expire 2027-06-15**.
- **Exact entitlements the profiles authorize** (use these verbatim when I
  write the `.entitlements` files in Phase 2):

  | | App | Extension |
  | --- | --- | --- |
  | `com.apple.application-identifier` | `KK7E9G89GW.org.sockpuppet.WikiFS` | `KK7E9G89GW.org.sockpuppet.WikiFS.FileProvider` |
  | `com.apple.security.application-groups` | `group.org.sockpuppet.wiki` | `group.org.sockpuppet.wiki` |
  | `com.apple.developer.team-identifier` | `KK7E9G89GW` | `KK7E9G89GW` |

  (Both also carry an auto-added `KK7E9G89GW.*` wildcard in app-groups and
  keychain-access-groups; we only use the explicit `group.org.sockpuppet.wiki`.)

**Remaining:** steps 6–7 — my job, in Phase 2 (embed profiles + inside-out
codesign in `build.sh`; switch the dev loop to `make install`).

## Division of labor

**Only a human can do these** (need Apple ID auth / portal login):
the certificate, device registration, App IDs, App Group, provisioning
profiles, and any macOS approval prompts.

**`build.sh` / app code handles** (automated): assembling the `.appex` under
`Self Driving Wiki.app/Contents/PlugIns/`, the extension `NSExtension` Info.plist keys,
both `.entitlements` files, embedding the downloaded `.provisionprofile`s,
inside-out codesigning, and `NSFileProviderManager.add(domain:)` at runtime.

## Manual checklist (do once, in order)

1. **Install an Apple Development certificate** into the login keychain.
   - Xcode → Settings → Accounts → [Apple ID] → Manage Certificates → + →
     **Apple Development**. (Xcode-as-cert-tool is fine; we still don't build
     with it.)
   - Verify: `security find-identity -v -p codesigning` shows
     `Apple Development: Thomas Ptacek (…)`.
2. **Register this Mac as a device.** developer.apple.com → Devices → + →
   Platform **macOS** → Provisioning UDID `00006050-00190839016B401C`.
3. **Create the App Group.** Identifiers → App Groups → + →
   `group.org.sockpuppet.wiki`. *(Done — the working group is `…wiki`; an
   earlier `…wikifs` attempt got fouled up in the portal.)*
4. **Create two explicit App IDs**, each with **App Groups** enabled and the
   group above assigned:
   - `org.sockpuppet.WikiFS`
   - `org.sockpuppet.WikiFS.FileProvider`
   (No "File Provider" capability toggle exists — the replicated extension is
   declared in the appex Info.plist. App Groups is the only managed capability.)
5. **Create two macOS App Development provisioning profiles** (Profiles → + →
   macOS App Development), one per App ID, tied to the dev cert + this device.
   Download both and place them in `signing/`:
   - `signing/WikiFS.provisionprofile`
   - `signing/WikiFSFileProvider.provisionprofile`
6. **Tell me the cert name** so I can set `DEV_IDENTITY` in the `Makefile`, and
   I'll wire `build.sh` to embed the profiles + codesign inside-out.
7. **Dev loop becomes `make install`** (copy to `/Applications` + LaunchServices
   register), because File Provider extensions are only discovered for an app
   in `/Applications`, launched once. Then the mount appears at
   `~/Library/CloudStorage/WikiFS`.

## Gotchas (read when it doesn't work)

- **Sandbox is mandatory for App Groups.** Enabling App Sandbox (off today) may
  surface new restrictions — notably **Phase 4's agent launch**: a sandboxed
  app spawning arbitrary `Process`es is restricted. Plan to launch the agent
  outside the sandbox or with explicit entitlements.
- **Silent failures.** A misconfigured File Provider domain just doesn't
  appear — no dialog. Debug with:
  `log stream --predicate 'subsystem == "com.apple.fileprovider"'` and watch
  the `fileproviderd` process.
- **Entitlements ⊆ profile.** Every entitlement in a `.entitlements` file must
  be authorized by the embedded profile, or launch dies with a vague AMFI /
  codesign error.
- **Inside-out signing.** Sign the `.appex` (its own entitlements + profile)
  first, then the `.app`.
- **Profiles expire (~1 year).** Renew = re-download into `signing/`, rebuild.

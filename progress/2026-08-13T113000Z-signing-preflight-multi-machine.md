---
timestamp: 2026-08-13T113000Z
title: Signing preflight — self-repairing setup that works on every Mac
branch: feature/signing-preflight-multi-machine
status: complete
---

# Signing preflight — self-repairing setup that works on every Mac

## Progress

`make build` now runs `signing/preflight.py` first. The preflight checks the
three provisioning profiles offline in about 0.2 seconds. It repairs them
against the Apple Developer account when a check fails.

Two defects made a multi-machine setup impossible.

**Per-machine profiles.** `signing/setup.sh` deleted each profile by name and
created it again with only the Mac that ran the script. Provisioning a second
laptop removed the first laptop from the profile, and the reverse. The failure
is silent: a profile that omits your Mac still signs, and AMFI then stops the
app at launch with no crash report. The preflight now builds one profile set
that carries every enabled Mac and every valid development certificate. The
certificate union matters as much as the device union, because each laptop holds
a different private key.

**A fixed daemon bundle id.** `WikiDaemonConnection.serviceName` hardcoded
`com.selfdrivingwiki.wikid`. An App ID is globally unique across App Store
Connect, so only the team that registered that id could issue a profile for it.
Every other developer got a `wikid.xpc` signed with no entitlements. That daemon
starts and still reaches the App Group container by literal path, but it cannot
reach the shared keychain, so agent credentials read back empty at ingest time.
`DAEMON_BUNDLE_ID` now derives from the app bundle id as `<BUNDLE_ID>.wikid`.
`build.sh`, the `Makefile`, and `WikiIdentifiers.daemonServiceID` use the same
derivation, so the client, the service bundle, and the profile agree.

Decisions worth recording:

- **Create before delete.** A replacement profile is downloaded and re-checked
  before the profile it supersedes is deleted. An interrupted repair leaves the
  old working set in place. Deletion is limited to profiles for the same bundle
  id whose name the tool owns.
- **Never fail the build.** No `asc`, no Apple account, or no config produces a
  report and exit 0. `build.sh` falls back to ad-hoc signing, as before.
- **A brake on the portal step.** App Store Connect has no App Groups API. When
  a profile comes back without the App Group, the preflight deletes that useless
  profile, prints the portal steps, and writes `signing/.portal-pending`. It
  then stops retrying for six hours, so a build does not repeat work that only a
  human can finish.
- **`build.sh` rejects an unusable daemon profile.** An entitlement the embedded
  profile does not grant is worse than no entitlement, because AMFI stops the
  process at exec instead of merely denying keychain access.

`signing/setup.sh` remains the first-run path for a new Apple account. It no
longer creates profiles. A second or third laptop of an account that is already
set up needs plain `make`: the preflight infers the identifiers from the account
and writes `signing/local.config`.

Documentation: `plans/signing-preflight.md` (new), `signing/README.md`,
`plans/signing.md`, `signing/local.config.example`, `PLAN.md` index.

## Verification

- `make build` — full build, signed with the real identity, File Provider
  enabled.
- `make signing-status` — reports both Macs in the app and extension profiles.
- `make signing-repair-dry-run` — prints the intended Apple API calls, including
  the deletions, and makes none of them.
- Repair on this machine: the app and extension profiles went from one Mac to
  two, the superseded and INVALID profiles were removed, and the
  `com.jjpdev.WikiFS.wikid` App ID was created.
- Second preflight run: 0.38 seconds, no network calls, one reminder line about
  the pending portal step.
- `WIKIFS_APP_TESTS=1 swift test --filter
  'serviceNameMatchesXPCBundleIdentifier|daemonServiceIDDefaultsToAppBundleIDSuffix'`
  — both pass.
- Built bundle checked: app `Info.plist` `WIKIDaemonServiceID`, `wikid.xpc`
  `CFBundleIdentifier`, and `wiki-identifiers.env` all read
  `com.jjpdev.WikiFS.wikid`.

Not verified: the daemon's entitled path. `wikid.provisionprofile` still needs
the App Group bound to `com.jjpdev.WikiFS.wikid` in the Apple portal. Until then
`build.sh` signs `wikid.xpc` without entitlements and prints the warning. The
second laptop and new-developer paths are implemented but were not exercised on
real hardware.

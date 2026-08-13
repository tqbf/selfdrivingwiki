# Signing preflight — one profile set for every Mac

Last verified: 2026-08-13

`signing/preflight.py` checks the code-signing setup before each build. It
repairs the setup when a check fails. `make build` runs it first.

This document explains what it checks, what it changes, and why the old
per-machine setup could not work for more than one Mac.

## The problem

Development provisioning profiles name the Macs they are valid for. The old
`signing/setup.sh` deleted each profile by name and created it again with only
the machine that ran the script. A second laptop removed the first laptop from
the profile. The first laptop then removed the second. Two machines could not
hold a working setup at the same time.

The failure is silent. A profile that omits your Mac still signs the app. AMFI
stops the app at launch with no crash report.

A second problem blocked the daemon for everybody except one team. The `wikid`
XPC service used a fixed bundle id, `com.selfdrivingwiki.wikid`. An App ID is
globally unique across App Store Connect. Only the team that registered that id
could make a profile for it. Every other developer got a `wikid.xpc` signed with
no entitlements. That daemon starts, but it cannot read the shared keychain, so
agent credentials come back empty at ingest time.

## What the preflight does

The check is offline. It costs about 0.2 seconds and makes no network calls.
For each of the three bundles — app, File Provider extension, and `wikid` — it
reads the profile in `signing/` and tests:

1. The profile exists and decodes.
2. The profile is not expired, and more than 30 days remain.
3. The `application-identifier` matches the configured bundle id.
4. The profile authorizes the App Group.
5. The profile authorizes the keychain access group (app and daemon only).
6. The profile lists this Mac's Provisioning UDID.
7. The keychain holds one of the certificates the profile names.

If all checks pass, the preflight exits. If a check fails, it repairs.

## What the repair does

The repair calls the App Store Connect API through the `asc` CLI. It follows
three rules.

**Every profile carries every Mac and every certificate.** The repair reads all
enabled Macs and all valid development certificates in the account, then puts
the whole set in the profile. One profile set works on all of your machines.
Each laptop holds a different private key, so the certificate union matters as
much as the device union.

**Create before delete.** The repair creates the new profile, downloads it, and
applies the same checks to it. It deletes the profile that the new one replaces
only after that. An interrupted repair leaves the old working profiles in place.
Deletion is limited to profiles for the same bundle id whose name the tool owns,
so a profile you made by hand stays.

**Never break the build.** No `asc`, no Apple account, or no config is not an
error. The preflight reports what is degraded and exits 0. `build.sh` then falls
back to ad-hoc signing, as before.

The repair also reuses work. If the account already holds an ACTIVE profile that
covers this Mac and all the others, the repair downloads it and changes nothing.

## The one manual step

App Store Connect has no API for App Groups. A human must create the App Group
and bind it to each bundle id in the portal. The preflight detects this case: it
creates the profile, sees that the App Group is absent from it, deletes the
useless profile, and prints the exact portal steps.

It then writes `signing/.portal-pending` and stops retrying for six hours.
Without that brake, every build would repeat a repair that only a human can
finish. `make signing-repair` ignores the brake.

## Per-developer daemon id

`DAEMON_BUNDLE_ID` now derives from your app bundle id as `<BUNDLE_ID>.wikid`.
Three places must agree on this string:

- `build.sh` writes it into the `wikid.xpc` `CFBundleIdentifier`, the app
  `Info.plist` key `WIKIDaemonServiceID`, and the `wiki-identifiers.env` sidecar.
- `WikiIdentifiers.daemonServiceID` resolves it at runtime through the usual
  chain: environment variable, `Info.plist`, sidecar, `signing/local.config`,
  compiled default.
- `WikiDaemonConnection.serviceName` and `wikid`'s own
  `WikiDaemonServiceName` both read that resolved value.

Set `DAEMON_BUNDLE_ID` in `signing/local.config` to override the derivation.

`build.sh` also refuses a daemon profile that does not cover this App ID, this
App Group, and this Mac. An entitlement that the embedded profile does not grant
is worse than no entitlement. AMFI stops the process at exec.

## Commands

| Command | What it does |
| --- | --- |
| `make signing-status` | Reports certificates, profiles, and identifiers. No changes. |
| `make signing-repair` | Provisions what is missing. Calls the Apple API. |
| `make signing-repair-dry-run` | Prints the Apple API calls without making them. |
| `make build` | Runs the check first, and repairs if needed. |

`WIKI_SIGNING_PREFLIGHT=0` skips the preflight. `CI=1` skips it too.

## The three cases this supports

**A laptop that is already set up.** The check passes offline. Nothing happens.

**Another laptop of the same developer.** `signing/local.config` is gitignored,
so a fresh clone has no identifiers. The preflight reads them back from the
account: it finds the one `*.WikiFS` bundle id, takes the team from its seed id,
and reads the App Group out of an existing profile. It then downloads a profile
that covers this Mac, or creates one that covers all of them. Plain `make` is
enough. You do not need `signing/setup.sh`.

**A new developer.** The account holds no WikiFS bundle ids, so the preflight
cannot guess a namespace. It says to run `./signing/setup.sh --prefix com.you`
and exits 0. The build continues with ad-hoc signing. `setup.sh` remains the
first-run path: it picks the prefix, mints certificates, registers the Mac,
creates the bundle ids, and hands the profiles to the preflight.

## Files

| File | Role |
| --- | --- |
| `signing/preflight.py` | The check and repair engine. Python 3 standard library only. |
| `signing/setup.sh` | First-run bootstrap for a new Apple account. Delegates profiles to the preflight. |
| `signing/local.config` | Per-developer identifiers. Gitignored. The preflight writes missing keys. |
| `signing/.portal-pending` | Records the bundle ids that wait for the portal step. Gitignored. |

See also [`plans/signing.md`](signing.md) for the Apple portal checklist and
[`plans/keychain-sharing.md`](keychain-sharing.md) for the keychain access group.

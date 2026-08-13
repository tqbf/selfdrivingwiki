# signing/

Per-developer code-signing setup. Everything here except the scripts is
gitignored, because it is specific to one Apple Developer account.

## Normal use

Run `make`. The build runs `signing/preflight.py` first. The preflight checks
the three provisioning profiles and repairs them if a check fails. It works on
any of your Macs, including one that has never built this repo.

| Command | What it does |
| --- | --- |
| `make signing-status` | Reports certificates, profiles, and identifiers. No changes. |
| `make signing-repair` | Provisions what is missing. Calls the Apple API. |
| `make signing-repair-dry-run` | Prints the Apple API calls without making them. |

## First run against a new Apple account

Run `./signing/setup.sh --prefix com.yourname`. It picks your identifiers, mints
the certificates, registers this Mac, creates the bundle ids, and then calls the
preflight for the profiles.

You do not need `setup.sh` on a second or third laptop of an account that is
already set up. The preflight reads the identifiers back from your account.

## The files

| File | Notes |
| --- | --- |
| `WikiFS.provisionprofile` | App — App ID `<BUNDLE_ID>` |
| `WikiFSFileProvider.provisionprofile` | Extension — App ID `<BUNDLE_ID>.FileProvider` |
| `wikid.provisionprofile` | XPC daemon — App ID `<BUNDLE_ID>.wikid` |
| `local.config` | Your identifiers. The preflight writes missing keys. |
| `local.config.example` | The template, with every key documented. |
| `.portal-pending` | Bundle ids that wait for the manual portal step. |

`build.sh` embeds the three profiles into the `.app`, the `.appex`, and
`wikid.xpc` at sign time. Profiles expire after about one year. The preflight
renews them when fewer than 30 days remain.

## Why the daemon needs its own profile

Without `wikid.provisionprofile`, `build.sh` signs `wikid.xpc` with no
entitlements. The daemon still starts and still reaches the App Group container
by literal path, because it is not sandboxed. It cannot reach the **shared
keychain**. Agent credentials then read back empty at ingest time, far from this
cause. The build prints a warning when the profile is absent or unusable.

The daemon bundle id derives from your app bundle id. It is not a shared
constant. An App ID is globally unique across App Store Connect, so a fixed id
is provisionable by exactly one team and by nobody else.

## The one step no API can do

App Store Connect cannot create an App Group or bind it to a bundle id. When the
preflight needs that, it prints the exact portal steps and stops retrying for six
hours. Do the steps, then run `make signing-repair`.

Full detail: [`../plans/signing-preflight.md`](../plans/signing-preflight.md).
Apple portal checklist: [`../plans/signing.md`](../plans/signing.md).

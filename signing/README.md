# signing/

Drop your downloaded macOS App Development provisioning profiles here:

- `WikiFS.provisionprofile`             (App ID org.sockpuppet.WikiFS)
- `WikiFSFileProvider.provisionprofile` (App ID org.sockpuppet.WikiFS.FileProvider)
- `wikid.provisionprofile`              (App ID com.selfdrivingwiki.wikid — the sandboxed XPC service)

`build.sh` embeds these into the app, `.appex`, and `wikid.xpc` bundles at
sign time. They're machine/team-specific and **gitignored** — re-download
from developer.apple.com when they expire (~1 yr). `signing/setup.sh`
generates all three automatically.

**`wikid.provisionprofile` is required for the daemon to work.** Without it,
`build.sh` signs `wikid.xpc` with NO entitlements, so the daemon runs
un-sandboxed AND can't reach the App Group container or shared keychain — it
will fail to open the shared store at runtime. The build prints a loud
warning when it's missing.

Full setup checklist: ../plans/signing.md

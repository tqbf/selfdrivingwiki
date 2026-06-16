# File Provider — build & gotchas (proven by the spike)

On 2026-06-15 a throwaway spike got a real `NSFileProviderReplicatedExtension`
working end to end: built with SwiftPM (no Xcode project), hand-assembled into a
`.appex`, signed inside-out with the dev profiles, registered as a domain, and
read from Terminal with `find` / `cat` / `grep`. This documents everything that
was non-obvious, so Phase 2 doesn't re-suffer it.

> The spike code lives in `Sources/WikiFSFileProvider/` + the registration UI in
> `Sources/WikiFS/FileProviderSpike.swift` / `WelcomeView.swift`. It serves a
> **static, hardcoded** tree. Phase 2 swaps the static `Catalog` for a read-only
> SQLite projection; the plumbing below stays.

## The five gotchas (each one cost real time)

### 1. Entitlements must be a SUBSET of the provisioning profile
Our dev profiles do **not** grant `get-task-allow` (verify with
`security cms -D -i signing/WikiFS.provisionprofile`). Claiming it in the
`.entitlements` → AMFI **SIGKILLs the process at exec** (exit 137), with **no
crash report and nothing in the log** you can read from a sandboxed shell. The
fingerprint: bare-signing the same bundle (no entitlements) launches fine.
**Rule:** entitlements ⊆ profile entitlements. We ship only
`com.apple.application-identifier` + `com.apple.developer.team-identifier`
(app) plus `app-sandbox` + `application-groups` (extension).

### 2. The Mach-O entry point must BE `_NSExtensionMain` — not a Swift `main()`
SwiftPM makes an `executableTarget`'s entry a Swift `main()`. If that `main()`
calls `NSExtensionMain()`, the extension **infinitely recurses and SIGSEGVs**
("Thread stack size exceeded due to excessive recursion"). Why: ExtensionFoundation
*re-invokes the binary's entry point* to run the principal class; that entry
must be the re-entrant `NSExtensionMain` itself. **Fix:** override the entry via
a linker flag — `-Xlinker -e -Xlinker _NSExtensionMain` (see `Package.swift`).
`main.swift` then only exists to satisfy SwiftPM; its `main()` is dead code.
This is *the* reason app extensions are hard to build outside Xcode.

### 3. A third-party File Provider must be ENABLED by the user
After registering the domain, it sits at `enabled: no` and `fileproviderd`
never starts the extension → every I/O against the mount **times out (os error
60)**. The user must flip it on: **System Settings → General → Login Items &
Extensions → (the "File Provider" row for the app) → ⓘ → toggle on**.
`NSExtensionFileProviderEnabledByDefault=true` did **not** bypass this for a
third-party extension (it's a deliberate consent gate). `pluginkit -e use -i
<id>` sets the plugin flag but does **not** flip the domain's enabled state.

### 4. The app must live in `/Applications` and be launched once
`pluginkit` only discovers the `.appex` when its containing app is in
`/Applications` and registered with LaunchServices. Dev loop is therefore
`make install` (not `make run` from `build/`).

### 5. First codesign with a fresh cert needs a one-time keychain approval
The first `codesign` with a newly created identity throws
`errSecInternalComponent` from a non-interactive shell (macOS pops a "codesign
wants to use the key" dialog). Approve it once ("Always Allow"); subsequent
signs are non-interactive.

## How the build is wired

- **Two SwiftPM executable targets**: `WikiFS` (app) and `WikiFSFileProvider`
  (extension binary), the latter with `.linkedFramework("FileProvider")` and the
  `-e _NSExtensionMain` entry override.
- **`build.sh`** assembles `Self Driving Wiki.app/Contents/PlugIns/WikiFSFileProvider.appex`
  by hand: copies the binary, writes the appex `Info.plist`
  (`CFBundlePackageType = XPC!`, `NSExtension` dict with point id
  `com.apple.fileprovider-nonui`, principal class `FileProviderExtension`,
  `NSExtensionFileProviderDocumentGroup = group.org.sockpuppet.wiki`), embeds
  the provisioning profiles, and **signs inside-out** (appex first with its
  entitlements, then the app).
- **Principal class** is `@objc(FileProviderExtension)` so the Obj-C runtime
  name matches `NSExtensionPrincipalClass` (Swift would otherwise mangle it).

## Minimum replicated-extension surface (what the spike implements)

- `NSFileProviderReplicatedExtension`: `init(domain:)`, `invalidate()`,
  `item(for:request:)`, `fetchContents(for:version:request:)`,
  `enumerator(for:request:)`, and read-only stubs for
  `createItem`/`modifyItem`/`deleteItem` (return a "read-only" error).
- `NSFileProviderEnumerator`: `enumerateItems(for:startingAt:)` →
  `didEnumerate` + `finishEnumerating(upTo: nil)`; constant sync anchor.
- `NSFileProviderItem`: identifier, parent, filename, `contentType`,
  read-only `capabilities`, `documentSize`, constant `itemVersion`.
- App side: `NSFileProviderManager.add(_:)`, then
  `getUserVisibleURL(for: .rootContainer)` for the path (never hardcode it).

## Diagnostics that actually worked (sandboxed shell can't read the unified log)

- `fileproviderctl dump` — domain state, `enabled:`, `not running`, errors. **The
  most useful tool.**
- `pluginkit -m -i <id> -vvv` — is the extension discovered / enabled (`+`/`-`).
- Crash reports at `~/Library/Logs/DiagnosticReports/WikiFSFileProvider-*.ips` —
  parse the triggered thread's backtrace (that's how the recursion was found).
- Running the appex binary directly prints "An XPC Service cannot be run
  directly" (SIGABRT) when the entry point is healthy.

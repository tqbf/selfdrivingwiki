import Foundation

/// Per-developer signing/runtime identifiers: the **App Group** the app + File
/// Provider extension share, and the extension's **bundle id**.
///
/// These used to be hardcoded to one developer's Apple Developer team. App
/// Groups and bundle ids are *globally unique* across App Store Connect, so
/// anyone who clones this repo must build against their OWN ids — they cannot
/// reuse the author's. To keep **zero per-user values in committed source**, the
/// values are resolved at runtime, first hit wins:
///
///  1. **Environment variable** — dev/test override; inherited by child processes.
///  2. **`Bundle.main` Info.plist key** — `build.sh` injects these into the
///     `.app` and `.appex` so the GUI app and the extension agree.
///  3. **Sidecar `wiki-identifiers.env` next to the executable** — covers
///     `wikictl`, a plain CLI with no Info.plist; `build.sh` drops the file
///     beside the binary (both in `build/` and in the app's `Contents/Helpers`).
///  4. **Compiled-in default** — so a fresh `swift build` / `swift test` works
///     with no signing setup at all.
///
/// `signing/setup.sh` provisions the ids against the cloner's account and writes
/// `signing/local.config`; `build.sh` reads that and propagates the values into
/// (2) and (3). See `plans/signing.md`.
public enum WikiIdentifiers {
    /// The App Group container both sides of the projection share
    /// (`~/Library/Group Containers/<appGroupID>/`). See ``DatabaseLocation``.
    public static let appGroupID = resolve(
        env: "WIKI_APP_GROUP_ID",
        infoKey: "WIKIAppGroupID",
        localConfigKey: "APP_GROUP",
        default: "group.org.sockpuppet.wiki")

    /// The File Provider extension's bundle id, used to query/repair its
    /// `pluginkit` registration. Must equal the `.appex`'s CFBundleIdentifier.
    public static let fileProviderID = resolve(
        env: "WIKI_FILE_PROVIDER_ID",
        infoKey: "WIKIFileProviderID",
        localConfigKey: "EXT_BUNDLE_ID",
        default: "org.sockpuppet.WikiFS.FileProvider")

    /// The `wikid` XPC service's bundle id — the name clients pass to
    /// `NSXPCConnection(serviceName:)`, and the `CFBundleIdentifier` of
    /// `Contents/XPCServices/wikid.xpc`.
    ///
    /// Per-developer for the same reason as the ids above, and the reason is
    /// load-bearing: the daemon needs an **explicit App ID** to carry the App
    /// Group + keychain entitlements (a wildcard App ID cannot hold App
    /// Groups), and App IDs are globally unique across App Store Connect. A
    /// shared constant is therefore unprovisionable by anyone except the one
    /// team that registered it — every other developer gets a `wikid.xpc`
    /// signed with no entitlements, which cannot reach the shared keychain.
    ///
    /// Defaults to `<app bundle id>.wikid`, matching `build.sh`'s derivation,
    /// so the id tracks whatever namespace the developer provisioned. Set
    /// `DAEMON_BUNDLE_ID` in `signing/local.config` to override.
    public static let daemonServiceID = resolve(
        env: "WIKI_DAEMON_SERVICE_ID",
        infoKey: "WIKIDaemonServiceID",
        localConfigKey: "DAEMON_BUNDLE_ID",
        default: derivedDaemonServiceID)

    /// `<app bundle id>.wikid` — the fallback used when nothing sets the daemon
    /// id explicitly. Mirrors `DAEMON_BUNDLE_ID="${BUNDLE_ID}.wikid"` in
    /// `build.sh`, including the compiled-in app-id default for fresh clones.
    private static var derivedDaemonServiceID: String {
        let appID = localConfig["BUNDLE_ID"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "org.sockpuppet.WikiFS"
        return appID + ".wikid"
    }

    // MARK: - Resolution

    /// Resolve a per-developer id, first hit wins:
    ///  1. **Environment variable** — dev/test override; inherited by children.
    ///  2. **`Bundle.main` Info.plist key** — `build.sh` injects these into the
    ///     `.app` and `.appex` so the GUI app and the extension agree.
    ///  3. **Sidecar `wiki-identifiers.env` next to the executable** — covers the
    ///     bundled `Contents/Helpers/wikictl` CLI.
    ///  4. **`signing/local.config`** (gitignored, per-developer) — the SAME file
    ///     `build.sh` reads. Lets a plain SwiftPM CLI like `.build/debug/wikictl`
    ///     (no Info.plist, no sidecar) resolve the developer's REAL ids without
    ///     an env var, so values can never drift from the built `.app`. Absent
    ///     for fresh clones / CI → falls through to the default.
    ///  5. **Compiled-in default** — so a fresh `swift build` / `swift test`
    ///     works with no signing setup at all.
    private static func resolve(
        env: String,
        infoKey: String,
        localConfigKey: String,
        default fallback: String
    ) -> String {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        if let v = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String, !v.isEmpty { return v }
        if let v = sidecar[env], !v.isEmpty { return v }
        if let v = localConfig[localConfigKey], !v.isEmpty { return v }
        return fallback
    }

    /// Parse shell-style `KEY=VALUE` lines (comments `#…` skipped, surrounding
    /// whitespace trimmed, surrounding double quotes stripped). Shared by the
    /// `wiki-identifiers.env` sidecar and `signing/local.config`.
    private static func parseKV(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// The running executable's path, resolved from `Bundle.main` (preferred)
    /// or, failing that, from `argv[0]`. May be a symlink — neither source
    /// resolves links.
    private static var executableURL: URL? {
        Bundle.main.executableURL
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
    }

    /// The directories to search for per-executable config, in order: the
    /// directory the binary was INVOKED from, then — when the invocation path is
    /// a symlink — the directory of the resolved TARGET.
    ///
    /// The resolved entry is what makes a symlinked install work.
    /// `Bundle.main.executableURL` reports the path the process was EXEC'd
    /// through, not the real file, so invoking the bundled `wikictl` through a
    /// `PATH` shim (`~/.local/bin/wikictl` → `…/Self Driving Wiki.app/Contents/
    /// Helpers/wikictl`, as Nix/Homebrew/`ln -s` all create) yielded only
    /// `~/.local/bin`. No sidecar exists there and the `signing/local.config`
    /// walk-up finds no repo, so `appGroupID` silently fell back to the
    /// compiled-in `group.org.sockpuppet.wiki` — a DIFFERENT, empty container.
    /// The symptom misleads: the exact same binary resolves every wiki when
    /// called by its bundle path and reports "no wiki matching <id> in the
    /// registry" through the symlink.
    ///
    /// The invoked directory is searched FIRST and is never dropped, so a
    /// sidecar deliberately placed beside a shim still wins over the target's.
    /// Adding the resolved directory is purely additive.
    static func candidateExecutableDirectories(for executable: URL) -> [URL] {
        let invoked = executable.deletingLastPathComponent()
        let resolved = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        // Compare with the invoked dir itself resolved, so a plain (non-symlink)
        // executable under a symlinked PARENT (`/var` → `/private/var`) yields
        // one directory rather than two spellings of the same place.
        if invoked.resolvingSymlinksInPath().path == resolved.path { return [invoked] }
        return [invoked, resolved]
    }

    /// `KEY=VALUE` pairs parsed once from `wiki-identifiers.env`. The keys match
    /// the environment-variable names (e.g. `WIKI_APP_GROUP_ID`). Empty when the
    /// file is absent — i.e. for the `.app`/`.appex` (which use the Info.plist
    /// path) and for plain test runs.
    ///
    /// Locations checked, in order, per candidate executable directory (invoked,
    /// then symlink-resolved — see ``candidateExecutableDirectories(for:)``):
    /// `build/wikictl` reads it from its own directory (the Phase A gate copy);
    /// the bundled `Contents/Helpers/wikictl` reads it from `../Resources`
    /// (build.sh can't leave plain files in the code-only Helpers dir); and the
    /// **enclosing `.app`'s `Contents/Resources`** — required by the `wikid`
    /// daemon, which as a bundled XPC service
    /// (`…/App.app/Contents/XPCServices/wikid.xpc`) has its executable four
    /// levels below the app's Resources. Without that third candidate the daemon
    /// finds NO sidecar (its own `.xpc/Contents/Resources` is empty) and — since
    /// a nested XPC service's `Bundle.main` Info.plist custom keys don't reliably
    /// surface either — falls through to the `group.org.sockpuppet.wiki` default,
    /// reading the WRONG App Group container (empty registry → "No store for
    /// wikiID" at ingest, and a stale 1-provider agent config). #887 follow-up.
    private static let sidecar: [String: String] = {
        guard let exe = executableURL else { return [:] }
        let candidates = candidateExecutableDirectories(for: exe).flatMap { exeDir -> [URL] in
            var perDir = [
                exeDir.appendingPathComponent("wiki-identifiers.env"),
                exeDir.deletingLastPathComponent()
                    .appendingPathComponent("Resources/wiki-identifiers.env"),
            ]
            if let appResources = enclosingAppResourcesDirectory(from: exeDir) {
                perDir.append(appResources.appendingPathComponent("wiki-identifiers.env"))
            }
            return perDir
        }
        guard let text = candidates.lazy
            .compactMap({ (url: URL) -> String? in
                DebugLog.trying("resolveAppGroupIDFromFile", operation: { try String(contentsOf: url, encoding: .utf8) })
            })
            .first
        else { return [:] }
        return parseKV(text)
    }()

    /// `<enclosing .app>/Contents/Resources`, found by walking up from `exeDir`
    /// to the nearest ancestor whose path component ends in `.app`, or `nil` if
    /// the executable isn't inside a `.app` (e.g. a `swift run` dev CLI). Lets a
    /// nested bundle (the `wikid.xpc` daemon) read the app-level id sidecar.
    static func enclosingAppResourcesDirectory(from exeDir: URL) -> URL? {
        var url = exeDir
        for _ in 0..<8 {
            if url.pathExtension == "app" {
                return url.appendingPathComponent("Contents/Resources", isDirectory: true)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }   // reached filesystem root
            url = parent
        }
        return nil
    }

    /// `signing/local.config` (gitignored, per-developer) parsed once — the SAME
    /// file `build.sh` reads to build the `.app`. Keys are the build.sh names
    /// (`APP_GROUP`, `EXT_BUNDLE_ID`, …), NOT the env-var names. Found by
    /// walking UP from each candidate executable directory (invoked, then
    /// symlink-resolved) until a repo root containing `signing/local.config` is
    /// located, so a SwiftPM CLI at `.build/debug/` reaches it two levels up —
    /// including when invoked through a symlink from elsewhere.
    ///
    /// This lets a plain CLI (no Info.plist, no sidecar) resolve the developer's
    /// REAL ids, matching the built `.app`, without any env var. Absent for fresh
    /// clones / CI → `[:]` → resolution falls through to the compiled default.
    private static let localConfig: [String: String] = {
        guard let exe = executableURL else { return [:] }
        for start in candidateExecutableDirectories(for: exe) {
            var dir = start
            for _ in 0..<10 {
                let candidate = dir.appendingPathComponent("signing/local.config")
                if let text = DebugLog.trying("resolveAppGroupIDFromSidecar", operation: { try String(contentsOf: candidate, encoding: .utf8) }) {
                    return parseKV(text)
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }   // reached filesystem root
                dir = parent
            }
        }
        return [:]
    }()
}

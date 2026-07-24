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

    /// The running executable's directory, resolved from `Bundle.main` (preferred)
    /// or, failing that, from `argv[0]`.
    private static var executableDir: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    /// `KEY=VALUE` pairs parsed once from `wiki-identifiers.env`. The keys match
    /// the environment-variable names (e.g. `WIKI_APP_GROUP_ID`). Empty when the
    /// file is absent — i.e. for the `.app`/`.appex` (which use the Info.plist
    /// path) and for plain test runs.
    ///
    /// Locations checked, in order, relative to the running executable:
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
        guard let exeDir = executableDir else { return [:] }
        var candidates = [
            exeDir.appendingPathComponent("wiki-identifiers.env"),
            exeDir.deletingLastPathComponent()
                .appendingPathComponent("Resources/wiki-identifiers.env"),
        ]
        if let appResources = enclosingAppResourcesDirectory(from: exeDir) {
            candidates.append(appResources.appendingPathComponent("wiki-identifiers.env"))
        }
        guard let text = candidates.lazy
            .compactMap({ try? String(contentsOf: $0, encoding: .utf8) })
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
    /// walking UP from the running executable until a repo root containing
    /// `signing/local.config` is located, so a SwiftPM CLI at `.build/debug/`
    /// reaches it two levels up.
    ///
    /// This lets a plain CLI (no Info.plist, no sidecar) resolve the developer's
    /// REAL ids, matching the built `.app`, without any env var. Absent for fresh
    /// clones / CI → `[:]` → resolution falls through to the compiled default.
    private static let localConfig: [String: String] = {
        guard var dir = executableDir else { return [:] }
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("signing/local.config")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return parseKV(text)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // reached filesystem root
            dir = parent
        }
        return [:]
    }()
}

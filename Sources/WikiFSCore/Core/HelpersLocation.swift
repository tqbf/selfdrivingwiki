import Foundation

/// Locates the embedded `wikictl` helper so the spawned agent can invoke it
/// (`plans/llm-wiki.md` Phase C — "ensure `wikictl` is resolvable: prepend
/// `Self Driving Wiki.app/Contents/Helpers` to the child's PATH").
///
/// `build.sh` embeds + codesigns `wikictl` at
/// `Self Driving Wiki.app/Contents/Helpers/wikictl` and ALSO drops a copy at
/// `build/wikictl` next to the dev binaries. We resolve the directory in priority
/// order so it works both from the signed bundle and from a `swift run` dev launch.
///
/// Moved from the app target to `WikiFSCore` so both the daemon and
/// `PdfExtractionService` (now in `WikiFSEngine`) can resolve helper paths.
public enum HelpersLocation {
    /// The directory that should be prepended to the agent's PATH so `wikictl`
    /// resolves. Returns the first directory that actually contains an executable
    /// `wikictl`, or the bundle Helpers dir as a best-effort fallback.
    public static var wikictlDirectory: String {
        for candidate in candidateDirectories() {
            let binary = candidate.appendingPathComponent("wikictl", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return candidate.path
            }
        }
        // Fallback: the canonical embedded location, even if we couldn't confirm
        // the binary (e.g. permissions) — better than an empty PATH segment.
        return bundleHelpersDirectory().path
    }

    /// Resolve a named helper binary (`bun`, `uv`, `wikictl`, …) bundled in the
    /// app's `Contents/Helpers`, searching the same candidate directories as
    /// ``wikictlDirectory``. Returns the absolute path if it exists and is
    /// executable, or `nil` if no candidate holds it.
    ///
    /// This is the single source of truth for "find a bundled helper" — it is
    /// XPC-service-aware (see ``bundleHelpersDirectory()``), so both the app and
    /// the `wikid.xpc` daemon resolve to the SAME `App.app/Contents/Helpers`.
    public static func bundledHelperPath(_ name: String) -> String? {
        for candidate in candidateDirectories() {
            let binary = candidate.appendingPathComponent(name, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return binary.path
            }
        }
        return nil
    }

    private static func candidateDirectories() -> [URL] {
        var directories: [URL] = []
        // 1. The signed app bundle's Contents/Helpers (production).
        directories.append(bundleHelpersDirectory())
        // 2. The dev build output dir (`build/wikictl`), relative to cwd.
        directories.append(URL(fileURLWithPath: "build", isDirectory: true))
        // 3. The directory of the running executable (covers `swift run`, where
        //    wikictl is built alongside the app binary).
        if let exe = Bundle.main.executableURL {
            directories.append(exe.deletingLastPathComponent())
        }
        return directories
    }

    /// The enclosing app bundle's `Contents/Helpers` directory.
    ///
    /// `build.sh` copies every helper (bun, uv, wikictl, …) into the OUTER app's
    /// `Contents/Helpers`. But when the running process is a nested bundle —
    /// notably the `wikid` daemon, now shipped as a bundled XPC service at
    /// `App.app/Contents/XPCServices/wikid.xpc` (#887) — `Bundle.main` is the
    /// `.xpc`, so a naive `Bundle.main.bundleURL/Contents/Helpers` points at
    /// `wikid.xpc/Contents/Helpers`, which does not exist. That silently broke
    /// bun/wikictl resolution in the daemon (ACP ingestion → "bun was not found
    /// on your PATH"). Walk up to the enclosing `.app` so nested bundles resolve
    /// to the app-level Helpers; fall back to `Bundle.main` for a `swift run`
    /// CLI with no `.app` ancestor (candidateDirectories covers that case).
    private static func bundleHelpersDirectory() -> URL {
        let base = enclosingAppBundleURL(from: Bundle.main.bundleURL) ?? Bundle.main.bundleURL
        return base
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
    }

    /// Nearest ancestor (or self) of `bundleURL` whose path component ends in
    /// `.app`, or `nil` when the process isn't running from inside a `.app`
    /// bundle (e.g. a `swift run` CLI launched from `.build/debug/`).
    ///
    /// Pure (takes the URL rather than reading `Bundle.main`) so the XPC-service
    /// nesting case can be unit-tested without an actual bundle.
    static func enclosingAppBundleURL(from bundleURL: URL) -> URL? {
        var url = bundleURL
        for _ in 0..<8 {
            if url.pathExtension == "app" { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }   // reached filesystem root
            url = parent
        }
        return nil
    }
}

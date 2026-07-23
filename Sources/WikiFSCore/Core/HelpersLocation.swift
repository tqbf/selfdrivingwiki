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

    private static func bundleHelpersDirectory() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
    }
}

#if PODCAST_TRANSCRIPTS  // Apple Podcasts transcript feature; off for WIKIFS_APP_STORE=1 builds.
import Foundation

/// Locates the signed `podcast-token-helper` Mach-O for THIS process. This is
/// the only Apple Podcasts Swift code that survives the TTML packaging: the
/// AMP request rules, the TTML parser, and the token subprocess/cache moved
/// into the reviewed `apple-podcast-transcript` package; the host keeps only
/// helper discovery (to stage the executable into the private operation root,
/// see the engine's `ReviewedApplePodcastSupportProvider`).
///
/// Resolution rules (unchanged): in the app bundle the helper lives in
/// `Contents/Helpers/` (sibling of `Contents/MacOS/`); in a dev/test build it
/// sits beside the built executable. Returns nil when absent, so hosts
/// degrade to "no staged support" (the package then uses its RSS fallback).
public enum HelperPodcastTokenProvider {
    /// The `podcast-token-helper` binary next to the running executable, or
    /// nil when this process ships no helper.
    public static func resolveHelperURL() -> URL? {
        let name = "podcast-token-helper"
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        guard let exeDir else { return nil }
        let candidates = [
            // App bundle: Contents/MacOS/<exe> → Contents/Helpers/<helper>.
            exeDir.deletingLastPathComponent().appendingPathComponent("Helpers/\(name)"),
            // Dev/test: beside the built executable.
            exeDir.appendingPathComponent(name),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
#endif

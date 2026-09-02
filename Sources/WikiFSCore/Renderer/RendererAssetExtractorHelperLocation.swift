import Foundation
import WikiFSTypes

// MARK: - RendererAssetExtractorHelperLocation

/// Deterministic resolution of the `renderer-asset-reference-extractor-helper`
/// executable (manifest revision 5 asset-read authority).
///
/// The resolver NEVER searches `PATH`. It checks a fixed candidate order:
///
/// 1. The signed app bundle: `…/Self Driving Wiki.app/Contents/Helpers/`
///    (the location `build.sh` stamps the helper into; matches `wikictl`).
/// 2. SwiftPM product siblings under `<repo>/.build/<configuration>/` —
///    both the canonical `.build/debug` and `.build/release`, so bare
///    `swift build` / `swift test` and `make build` / `make test` find the
///    sibling binary they just produced.
/// 3. A repository development candidate (`Sources/…/…` output location),
///    kept as a documented fallback for unusual checkouts.
///
/// Missing, nonregular, nonexecutable, or unverifiable helpers resolve to
/// `nil` — the caller fails closed to zero admitted assets while preserving
/// normal non-image rendering and source/raw fallback.
public enum RendererAssetExtractorHelperLocation {
    /// The helper binary's file name inside its helper directory (kebab-case
    /// as `build.sh` stamps it into the signed app bundle).
    public static let helperExecutableName = "renderer-asset-reference-extractor-helper"

    /// SwiftPM's executable product name (capitalized target name). The
    /// resolver accepts it as a sibling-build candidate; `build.sh` copies it
    /// to `Contents/Helpers` under the kebab-case name.
    public static let swiftPMProductName = "RendererAssetReferenceExtractorHelper"

    /// The relative path inside a signed app bundle: `Contents/Helpers/…`.
    public static let bundledRelativePath = "Contents/Helpers/\(helperExecutableName)"

    /// The deterministic candidate order. No environment, no PATH.
    public static func candidates(
        mainBundle: Bundle = .main,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) -> [URL] {
        var urls: [URL] = []

        // 1. Signed app bundle helper.
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: helperExecutableName) {
            urls.append(bundled)
        } else if mainBundle.bundleURL.pathExtension == "app" {
            // Some in-memory/edge bundles don't resolve auxiliary executables;
            // fall back to the literal Contents/Helpers path.
            urls.append(mainBundle.bundleURL.appendingPathComponent(bundledRelativePath))
        }

        // 2. SwiftPM product siblings. SwiftPM 6 places products under
        //    `.build/<triple>/<config>/` (e.g. `arm64-apple-macosx/debug`),
        //    and older layouts under `.build/<config>/`. Match both.
        if let buildRoot = Self.swiftPMBuildRoot(processInfo: processInfo, fileManager: fileManager) {
            let configurations = ["debug", "release"]
            for configuration in configurations {
                urls.append(buildRoot.appendingPathComponent("\(configuration)/\(swiftPMProductName)"))
                urls.append(buildRoot.appendingPathComponent("\(configuration)/\(helperExecutableName)"))
            }
            // `.build/<triple>/<config>/` — enumerate triple dirs.
            // Ignoring enumeration failure is correct: a `.build` that cannot
            // be listed simply contributes no triple candidates, and the
            // resolver degrades to the other deterministic candidates.
            // swiftlint:disable:next silent_try_optional
            if let contents = try? fileManager.contentsOfDirectory(at: buildRoot, includingPropertiesForKeys: nil) {
                for tripleDir in contents where tripleDir.hasDirectoryPath {
                    for configuration in configurations {
                        let configDir = tripleDir.appendingPathComponent(configuration, isDirectory: true)
                        var isDir: ObjCBool = false
                        guard fileManager.fileExists(atPath: configDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                        urls.append(configDir.appendingPathComponent(swiftPMProductName))
                        urls.append(configDir.appendingPathComponent(helperExecutableName))
                    }
                }
            }
        }

        // 3. Repository development candidate (rare; keeps the resolver
        //    deterministic without PATH).
        urls.append(
            URL(fileURLWithPath: "Sources/RendererAssetReferenceExtractorHelper/\(helperExecutableName)"))

        return urls
    }

    /// Resolve to the first candidate that is a regular, executable file.
    public static func locate(
        mainBundle: Bundle = .main,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) -> URL? {
        for candidate in candidates(mainBundle: mainBundle, fileManager: fileManager, processInfo: processInfo) {
            guard isExecutableFile(candidate, fileManager: fileManager) else { continue }
            return candidate
        }
        return nil
    }

    /// True only when `url` points at a regular file that the current user may
    /// execute. Symlinks are followed for the "regular" check but not resolved
    /// away for identity purposes.
    public static func isExecutableFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isRegular: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isRegular),
              isRegular.boolValue == false else { return false }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    /// Walk up from the current directory to find a directory named `.build`
    /// that contains a SwiftPM product directory (debug/release, either at
    /// `.build/<config>` or `.build/<triple>/<config>`). This is the standard
    /// SwiftPM on-disk layout for a package checked out at the repo root.
    private static func swiftPMBuildRoot(
        processInfo: ProcessInfo,
        fileManager: FileManager
    ) -> URL? {
        var current = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .standardizedFileURL
        while true {
            let build = current.appendingPathComponent(".build", isDirectory: true)
            if Self.hasSwiftPMProductLayout(build, fileManager: fileManager) {
                return build
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { return nil }
            current = parent
        }
    }

    private static func hasSwiftPMProductLayout(_ build: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        for configuration in ["debug", "release"] {
            let direct = build.appendingPathComponent(configuration, isDirectory: true)
            if fileManager.fileExists(atPath: direct.path, isDirectory: &isDir), isDir.boolValue { return true }
            // `.build/<triple>/<config>/`
            // Ignoring enumeration failure is correct: the same rationale as
            // the candidate builder — a `.build` that cannot be listed simply
            // contributes no triple candidates.
            // swiftlint:disable:next silent_try_optional
            if let contents = try? fileManager.contentsOfDirectory(at: build, includingPropertiesForKeys: nil) {
                for tripleDir in contents where tripleDir.hasDirectoryPath {
                    let configDir = tripleDir.appendingPathComponent(configuration, isDirectory: true)
                    if fileManager.fileExists(atPath: configDir.path, isDirectory: &isDir), isDir.boolValue { return true }
                }
            }
        }
        return false
    }
}

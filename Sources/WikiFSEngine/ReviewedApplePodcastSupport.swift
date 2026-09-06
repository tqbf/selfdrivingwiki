import Foundation
import WikiFSCore
import WikiFSTypes

// The reviewed-only host support for the exact compiled Apple Podcasts
// transcript package revision. Both services below admit by COMPLETE
// revision identity — package ID, version, and digest — and by nothing else:
// a kind, a MIME type, a manifest capability, a credential requirement, or a
// package-controlled string can never obtain the helper or the cache root.

/// The production `ExtractorOperationSupportProviding` for the reviewed Apple
/// package. Locates the signed `podcast-token-helper` through the existing
/// bundle/SwiftPM sibling rules, records its expected identity (SHA-256 +
/// byte count) at grant time, and returns nil — supported, not an error —
/// when the helper is absent (for example an App Store build) or the asked
/// revision is not the exact reviewed one.
public struct ReviewedApplePodcastSupportProvider: ExtractorOperationSupportProviding {
    private let revision: ExtractorPackageRevisionID

    public init(revision: ExtractorPackageRevisionID) {
        self.revision = revision
    }

    public func operationSupport(
        for revision: ExtractorPackageRevisionID
    ) -> ExtractorOperationSupportGrant? {
        // Exact identity only — including the digest, not just the ID.
        guard revision == self.revision else { return nil }
        #if PODCAST_TRANSCRIPTS
        guard let helperURL = HelperPodcastTokenProvider.resolveHelperURL() else {
            // A build without the helper is a supported state: the package
            // uses its RSS fallback. Not a host preparation failure.
            return nil
        }
        return Self.grant(helperURL: helperURL)
        #else
        // App Store builds ship no helper target at all.
        return nil
        #endif
    }

    #if PODCAST_TRANSCRIPTS
    static func grant(helperURL: URL) -> ExtractorOperationSupportGrant? {
        // An unreadable helper is the supported "no support" state, not an
        // error; the package falls back to RSS.
        // swiftlint:disable:next silent_try_optional
        guard let data = try? Data(contentsOf: helperURL) else { return nil }
        return ExtractorOperationSupportGrant(
            role: .podcastTokenHelper,
            sourceURL: helperURL,
            destinationFileName: "podcast-token-helper",
            expectedSHA256: ExtractorSHA256.digest(data).hex,
            expectedByteCount: data.count)
    }
    #endif
}

/// The durable, revision-scoped private token cache root for the reviewed
/// Apple package. Layout: `<layout root>/package-cache/<packageID>/<version>-<digest12>/`.
/// Owner-only directories; one directory per complete revision identity.
/// When the exact reviewed revision is prepared, sibling revision
/// directories of the same package (a superseded or retired revision) are
/// removed — the cache never outlives its reviewed revision's tenure.
public enum ReviewedApplePodcastTokenCache {

    /// The cache root for `revision`, or nil when `revision` is not the
    /// exact reviewed Apple revision. Creates the root owner-only and sweeps
    /// superseded sibling revisions. Errors are value-free (a nil return or
    /// a missing directory degrade to "no cache") so a malformed cache tree
    /// never blocks extraction.
    public static func root(
        for revision: ExtractorPackageRevisionID,
        reviewedRevision: ExtractorPackageRevisionID,
        layoutRoot: URL
    ) -> URL? {
        guard revision == reviewedRevision else { return nil }
        let packageRoot = layoutRoot
            .appendingPathComponent("package-cache", isDirectory: true)
            .appendingPathComponent(revision.packageID.rawValue, isDirectory: true)
        let revisionRoot = packageRoot
            .appendingPathComponent(
                "\(revision.version.rawValue)-\(revision.digest.hex.prefix(12))",
                isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: revisionRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            sweep(siblings: siblingDirectories(of: revisionRoot, in: packageRoot))
        } catch {
            DebugLog.extraction("Reviewed package token cache preparation failed")
            return nil
        }
        return revisionRoot
    }

    /// Removes every sibling revision directory under the package root —
    /// the cache of a superseded or retired revision.
    static func sweep(siblings: [URL]) {
        for url in siblings {
            // Best-effort: a stale sibling that cannot be removed must not
            // block the live revision's cache preparation.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func siblingDirectories(of root: URL, in packageRoot: URL) -> [URL] {
        // A missing or unreadable package root means "no cache yet"; the
        // caller degrades to no cache.
        // swiftlint:disable:next silent_try_optional
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: packageRoot,
            includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents.filter { url in
            // Unreadable resource values classify the entry as a file, which
            // then skips the sweep — safe for this internal cleanup.
            // swiftlint:disable:next silent_try_optional
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            return isDirectory && url.standardizedFileURL != root.standardizedFileURL
        }
    }
}

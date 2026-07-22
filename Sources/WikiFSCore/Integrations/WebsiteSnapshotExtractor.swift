import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Phase 4 — the pure + async website-snapshot extraction layer.
///
/// Given a fetched HTML page's raw text + its final (post-redirect) URL, this
/// produces a self-contained `WebsiteSnapshot`: the page's markdown (with image
/// `src`s rewritten to relative sibling paths) plus the downloaded image bytes.
///
/// The extraction is **off-main** (downloads run via the injected
/// `URLFetchService.URLResourceFetcher` seam — CI uses a fake, the app uses
/// `URLSessionFetcher`). The store is never touched here (single-writer
/// discipline: the `@MainActor` model owns the write).
///
/// Image identity model: images are **per-snapshot** — each snapshot owns its
/// image source rows. Only the blob is content-addressed/deduped (the store's
/// `addSnapshotImage` handles that). This extractor never decides dedup; it
/// downloads every resolved image and lets the store collapse identical blobs.
///
/// See `plans/graph-model-and-versioning.md` §7 (rendering rule + sibling
/// resolution), §4.2 (`original_path`), and Decision D4 (absolute srcs
/// normalized to relative `original_path` at materialize time).
public enum WebsiteSnapshotExtractor {

    // MARK: - Caps (product bounds)

    /// Per-image byte cap. An image larger than this is skipped (not fatal).
    static let maxImageBytes = 20 * 1024 * 1024  // 20 MB
    /// Maximum number of images per snapshot. Extra images are skipped.
    static let maxImageCount = 30
    /// Total byte budget across all images in one snapshot.
    static let maxTotalImageBytes = 50 * 1024 * 1024  // 50 MB

    // MARK: - Resolved image (pure)

    /// An image `src` resolved to its absolute download URL, paired with the
    /// original `src` attribute value (the key for the token-level rewrite).
    public struct ResolvedImage: Equatable, Sendable {
        public let absoluteURL: URL
        public let sourceSrc: String

        public init(absoluteURL: URL, sourceSrc: String) {
            self.absoluteURL = absoluteURL
            self.sourceSrc = sourceSrc
        }
    }

    /// Extract all resolvable `<img src>` from scoped tokens, resolving each
    /// against the page's final URL and de-duplicating by absolute URL.
    ///
    /// Skips non-`http(s)` schemes (data:, blob:, file:, mailto:) and empty
    /// srcs. Pure — no network, no store.
    public static func extractImages(
        from html: String, baseURL: URL
    ) -> [ResolvedImage] {
        let tokens = HTMLToMarkdown.scopedTokens(for: html)
        return extractImages(fromTokens: tokens, baseURL: baseURL)
    }

    /// Internal token-level variant (the snapshot path uses this directly with
    /// pre-scoped tokens; the public wrapper re-scopes for test convenience).
    static func extractImages(
        fromTokens tokens: [HTMLToMarkdown.Token], baseURL: URL
    ) -> [ResolvedImage] {
        var seen = Set<String>()
        var images: [ResolvedImage] = []
        for token in tokens {
            guard case let .startTag(name, attrs, _) = token, name == "img" else { continue }
            guard let src = attrs["src"], !src.isEmpty else { continue }
            guard let resolved = URL(string: src, relativeTo: baseURL)?.absoluteURL else { continue }
            guard let scheme = resolved.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            // Dedup by the (src, URL) pair — two different src strings that
            // resolve to the same URL are BOTH kept so the token-level rewrite
            // catches every variant (LOW-1 fix).
            let dedupKey = "\(src)\u{0}\(resolved.absoluteString)"
            guard !seen.contains(dedupKey) else { continue }
            seen.insert(dedupKey)
            images.append(ResolvedImage(absoluteURL: resolved, sourceSrc: src))
        }
        return images
    }

    // MARK: - Path computation (pure)

    /// Compute a relative `original_path` from a resolved image URL: strip the
    /// host root, drop `../` traversal, keep subpaths, and normalize the last
    /// component's extension to the inferred one. Falls back to
    /// `images/image.<ext>` when the path carries no useful component.
    public static func relativePath(for url: URL, fileExtension ext: String) -> String {
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        // Drop `../` traversal sequences (defensive — URL resolution already
        // collapses most, but a literal `..` in the path survives).
        while path.hasPrefix("../") { path.removeFirst(3) }
        if path.isEmpty { return "images/image.\(ext)" }

        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.isEmpty { return "images/image.\(ext)" }

        // Normalize the last component's extension.
        var last = components.removeLast()
        let ns = (last as NSString)
        let currentExt = ns.pathExtension.lowercased()
        if !ext.isEmpty && currentExt != ext.lowercased() {
            if currentExt.isEmpty {
                last = "\(last).\(ext)"
            } else {
                last = "\(ns.deletingPathExtension).\(ext)"
            }
        }
        components.append(last)
        return components.joined(separator: "/")
    }

    /// Infer the MIME type for downloaded image bytes: sniff magic bytes first,
    /// then trust the response content-type (when image/*), then the URL's
    /// extension via UTType. Falls back to `application/octet-stream`.
    public static func inferMIME(
        data: Data, responseContentType: String?, url: URL
    ) -> String {
        if let sniffed = ContentSniff.mimeType(of: data) { return sniffed }
        if let ct = responseContentType,
           let mime = URLFetchService.normalizedMIME(ct),
           mime.hasPrefix("image/" ) {
            return mime
        }
        let urlExt = (url.lastPathComponent as NSString).pathExtension.lowercased()
        #if canImport(UniformTypeIdentifiers)
        if !urlExt.isEmpty,
           let mime = UTType(filenameExtension: urlExt)?.preferredMIMEType {
            return mime
        }
        #endif
        return MimeType.octetStream
    }

    // MARK: - Disambiguation (pure)

    /// Disambiguate a list of candidate paths so no two collide, mirroring
    /// `MarkdownFolderReader`'s `-1/-2/…` suffix rule: the first occurrence
    /// keeps its path; subsequent collisions get `-\(n)` before the extension.
    ///
    /// Returns the paths in the same order as the input, plus the final
    /// `original_path` for each.
    public static func disambiguate(_ candidates: [String]) -> [String] {
        var seen: [String: Int] = [:]
        var result: [String] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            let count = seen[candidate, default: 0]
            seen[candidate, default: 0] += 1
            if count == 0 {
                result.append(candidate)
            } else {
                let ns = (candidate as NSString)
                let stem = ns.deletingPathExtension
                let ext = ns.pathExtension
                let suffix = ext.isEmpty
                    ? "\(stem)-\(count)"
                    : "\(stem)-\(count).\(ext)"
                result.append(suffix)
            }
        }
        return result
    }

    // MARK: - Token-level src rewrite (pure)

    /// Rewrite each `<img src>` in the scoped tokens to its assigned relative
    /// `original_path` (from `srcMap`). Tokens whose `src` is absent from the
    /// map are left verbatim. The tokenizer already normalized attribute
    /// quoting/casing, so this is strictly more robust than a string-level pass.
    static func rewriteImageSrcs(
        in tokens: [HTMLToMarkdown.Token], using srcMap: [String: String]
    ) -> [HTMLToMarkdown.Token] {
        tokens.map { token in
            guard case let .startTag(name, attrs, sc) = token, name == "img" else { return token }
            guard let src = attrs["src"], let newPath = srcMap[src] else { return token }
            var newAttrs = attrs
            newAttrs["src"] = newPath
            return .startTag(name: name, attributes: newAttrs, selfClosing: sc)
        }
    }

    // MARK: - Snapshot (async: download + assemble)

    /// A downloaded image awaiting path assignment.
    private struct Downloaded {
        let resolved: ResolvedImage
        let data: Data
        let responseContentType: String?
    }

    /// Build a complete `WebsiteSnapshot` from a fetched HTML page: scope tokens
    /// → extract images → download (with caps) → disambiguate paths → rewrite
    /// srcs → render markdown. Non-fatal skips are logged via `DebugLog`.
    ///
    /// - Parameters:
    ///   - html: The raw HTML text (post-decode).
    ///   - finalURL: The page's final (post-redirect) URL — the base for
    ///     resolving relative image srcs.
    ///   - fetcher: The injected fetcher (fake in CI, `URLSessionFetcher` in app).
    ///   - filename: The resolved page filename (from `<title>` or URL stem).
    ///   - provenance: The shared fetch provenance for the whole snapshot.
    ///   - plan: The dispatch plan (for `format` + filename propagation).
    public static func snapshot(
        html: String,
        finalURL: URL,
        fetcher: any URLFetchService.URLResourceFetcher,
        filename: String,
        provenance: SourceProvenance,
        plan: FormatPlan
    ) async throws -> WebsiteSnapshot {

        // 1. Scope to main content + extract images (pure). All src variants are
        //    kept (two srcs resolving to the same URL are both tracked).
        let scoped = HTMLToMarkdown.scopedTokens(for: html)
        let resolvedImages = extractImages(fromTokens: scoped, baseURL: finalURL)

        // 2. Download deduped by absolute URL (download once per URL), with caps.
        var downloadedByURL: [String: Downloaded] = [:]
        var downloadOrder: [String] = []  // preserve first-seen URL order
        var totalBytes = 0
        for image in resolvedImages {
            let urlKey = image.absoluteURL.absoluteString
            if downloadedByURL[urlKey] != nil { continue }  // already downloaded
            if downloadedByURL.count >= maxImageCount {
                DebugLog.store("snapshot: image \(image.absoluteURL) skipped: count cap (\(maxImageCount))")
                continue
            }
            do {
                let resp = try await fetcher.fetch(image.absoluteURL)
                if resp.data.isEmpty {
                    DebugLog.store("snapshot: image \(image.absoluteURL) skipped: empty")
                    continue
                }
                if resp.data.count > maxImageBytes {
                    DebugLog.store("snapshot: image \(image.absoluteURL) skipped: too large (\(resp.data.count) > \(maxImageBytes))")
                    continue
                }
                if totalBytes + resp.data.count > maxTotalImageBytes {
                    DebugLog.store("snapshot: image \(image.absoluteURL) skipped: byte budget exceeded")
                    continue
                }
                totalBytes += resp.data.count
                let d = Downloaded(resolved: image, data: resp.data, responseContentType: resp.contentType)
                downloadedByURL[urlKey] = d
                downloadOrder.append(urlKey)
            } catch {
                DebugLog.store("snapshot: image \(image.absoluteURL) skipped: \(error.localizedDescription)")
            }
        }

        // 3. Infer MIME → extension → candidate path per downloaded image (pure).
        //    MIME computed once and reused (LOW-2 fix).
        var mimes: [String: String] = [:]
        let candidates = downloadOrder.map { urlKey -> String in
            let d = downloadedByURL[urlKey]!
            let mime = inferMIME(data: d.data, responseContentType: d.responseContentType, url: d.resolved.absoluteURL)
            mimes[urlKey] = mime
            let ext = URLFetchService.binaryExtension(forMIME: mime, url: d.resolved.absoluteURL)
            return relativePath(for: d.resolved.absoluteURL, fileExtension: ext)
        }

        // 4. Disambiguate candidate paths (pure).
        let paths = disambiguate(candidates)

        // 5. Build urlKey → path map.
        var pathByURL: [String: String] = [:]
        for (i, urlKey) in downloadOrder.enumerated() {
            pathByURL[urlKey] = paths[i]
        }

        // 6. Build srcMap from ALL resolved images (every src variant gets an
        //    entry) + SnapshotImage list (one per downloaded URL).
        var srcMap: [String: String] = [:]
        for image in resolvedImages {
            let urlKey = image.absoluteURL.absoluteString
            if let path = pathByURL[urlKey] {
                srcMap[image.sourceSrc] = path
            }
        }
        var images: [SnapshotImage] = []
        for urlKey in downloadOrder {
            guard let d = downloadedByURL[urlKey], let path = pathByURL[urlKey] else { continue }
            let mime = mimes[urlKey] ?? MimeType.octetStream
            let filename = (path as NSString).lastPathComponent
            images.append(SnapshotImage(
                originalPath: path,
                filename: filename,
                data: d.data,
                mimeType: mime,
                sourceURL: d.resolved.absoluteURL))
        }

        // 6. Rewrite srcs in scoped tokens + render markdown (pure).
        let rewritten = rewriteImageSrcs(in: scoped, using: srcMap)
        let markdown = HTMLToMarkdown.markdown(fromScopedTokens: rewritten)

        // 7. Build the page source (issue #599: preserve the ORIGINAL HTML bytes
        //    as the source blob — mirrors the non-snapshot HTML path; the
        //    snapshot markdown with rewritten image srcs rides as the
        //    extracted-markdown sidecar on the FormatPlan and is written as a
        //    `.extraction`-origin processed-markdown version).
        let page = MaterializedSource(
            filename: filename,
            data: Data(html.utf8),
            mimeType: nil,
            provenance: provenance,
            extractedMarkdown: markdown)
        let snapshotPlan = FormatPlan(
            filename: filename,
            data: Data(html.utf8),
            format: .html,
            extractedMarkdown: markdown)
        return WebsiteSnapshot(page: page, images: images, plan: snapshotPlan)
    }
}

import Foundation
import Markdown
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core — deterministic projection from pinned source facts.

/// Immutable renderer plans for exact source IDs already resolved from typed
/// wiki embed syntax. Matching stays role-aware and fail-closed.
enum DocumentSourceRendererProjection {
    static func hasEligibleRenderer(
        mimeType: String?,
        fileExtension: String?,
        registry: RendererRegistrySnapshot,
        inlineCapableReferences: Set<RendererReference>
    ) -> Bool {
        let normalizedMIME: RendererMIMEType?
        if let mimeType {
            do {
                normalizedMIME = try RendererMIMEType(validating: mimeType)
            } catch {
                DebugLog.reader("Source renderer projection rejected an invalid MIME type.")
                return false
            }
        } else {
            normalizedMIME = nil
        }
        // Legacy rows can carry no MIME at all; the extension fallback tier
        // exists for exactly that case.
        guard normalizedMIME != nil || fileExtension != nil else { return false }
        return registry.descriptors.contains { descriptor in
            descriptor.compatibility.supports(hostProtocolRevision: registry.hostProtocolRevision) &&
                descriptor.supportedEmbeddingRoles.contains(.inlineContent) &&
                inlineCapableReferences.contains(descriptor.reference) &&
                descriptor.capabilities.contains(.inputRead) &&
                descriptor.matchers.contains(where: { matcher in
                    switch matcher {
                    case .normalizedMIME(let claimed):
                        claimed == normalizedMIME && normalizedMIME != nil
                    case .extensionFallback(let claimed):
                        claimed.rawValue == fileExtension && fileExtension != nil
                    default:
                        false
                    }
                })
        }
    }

    static func build(
        sources: [SourceID: RendererEmbeddedContent.Source],
        displayNames: [SourceID: String],
        registry: RendererRegistrySnapshot,
        inlineCapableReferences: Set<RendererReference>
    ) throws -> [SourceID: RendererEmbedPlan] {
        var plans: [SourceID: RendererEmbedPlan] = [:]
        for (sourceID, source) in sources {
            guard source.bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount,
                  let descriptor = try matchingDescriptor(
                      for: source,
                      registry: registry,
                      inlineCapableReferences: inlineCapableReferences)
            else { continue }
            plans[sourceID] = RendererEmbedPlan(
                placeholderID: "sdw-inline-renderer-\(source.digest.hex.prefix(16))",
                embeddingRole: .inlineContent,
                rendererReference: descriptor.reference,
                input: .source(source),
                semanticContent: "Source available as \(source.mimeType.rawValue).",
                displayTitle: displayNames[sourceID],
                activationMetadata: .init(
                    controlLabel: "Open",
                    accessibilityLabel: "Open inline source renderer",
                    summary: "Open the source in the renderer pane."))
        }
        return plans
    }

    private static func matchingDescriptor(
        for source: RendererEmbeddedContent.Source,
        registry: RendererRegistrySnapshot,
        inlineCapableReferences: Set<RendererReference>
    ) throws -> RendererDescriptor? {
        let sniffedBytes = Data(source.bytes.prefix(RendererMatchingLimits.maximumSniffByteCount))
        let input = try RendererMatchInput(
            mimeType: source.mimeType,
            fileExtension: source.fileExtension.flatMap { try RendererFileExtension(validating: $0) },
            sniffedBytes: sniffedBytes,
            sniffedBytesAreComplete: sniffedBytes.count == source.bytes.count,
            artifactKind: .source)
        return registry.matching(input, requiredEmbeddingRole: .inlineContent).first { descriptor in
            inlineCapableReferences.contains(descriptor.reference) &&
                descriptor.capabilities.contains(.inputRead) &&
                source.bytes.count <= descriptor.sizeLimits.maximumInputByteCount &&
                source.bytes.count <= descriptor.sizeLimits.maximumDecodedByteCount
        }
    }
}

/// Resolves only image destinations authored in the current Markdown. File
/// Provider paths become typed source IDs after their structure and current
/// source or bookmark facts match exactly.
enum MarkdownImageSourcePathResolver {
    static func resolve(
        markdown: String,
        sources: [SourceSummary],
        bookmarkNodes: [BookmarkNode]
    ) -> [String: SourceID] {
        let destinations = imageDestinations(in: markdown)
        guard destinations.isEmpty == false else { return [:] }
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let sourcesByShortID = Dictionary(grouping: sources, by: { FilenameEscaping.shortID($0.id.rawValue) })
        return destinations.reduce(into: [:]) { result, destination in
            let decoded = destination.removingPercentEncoding ?? destination
            if let sourceID = sourceID(
                for: decoded,
                sourcesByID: sourcesByID,
                sourcesByShortID: sourcesByShortID,
                bookmarkNodes: bookmarkNodes) {
                result[destination] = sourceID
            }
        }
    }

    private static func imageDestinations(in markdown: String) -> Set<String> {
        let document = Document(parsing: markdown)
        var result = Set<String>()
        func collect(_ markup: Markup) {
            if let image = markup as? Image, let source = image.source {
                result.insert(source)
            }
            for child in markup.children { collect(child) }
        }
        collect(document)
        return result
    }

    private static func sourceID(
        for path: String,
        sourcesByID: [SourceID: SourceSummary],
        sourcesByShortID: [String: [SourceSummary]],
        bookmarkNodes: [BookmarkNode]
    ) -> SourceID? {
        guard let components = rootedComponents(for: path) else { return nil }
        if components.count == 3, components[0] == "sources", components[1] == "by-id" {
            let rawID = (components[2] as NSString).deletingPathExtension
            let sourceID = SourceID(rawValue: rawID)
            guard let source = sourcesByID[sourceID],
                  components[2] == FilenameEscaping.byIDSourceFilename(sourceID: sourceID, ext: source.ext)
            else { return nil }
            return sourceID
        }
        if components.count == 3, components[0] == "sources", components[1] == "by-name" {
            let stem = ((components[2] as NSString).deletingPathExtension as NSString)
            let delimiter = stem.range(of: "--", options: .backwards)
            guard delimiter.location != NSNotFound else { return nil }
            let shortID = stem.substring(from: NSMaxRange(delimiter))
            let matches = (sourcesByShortID[shortID] ?? []).filter { source in
                let humanName = source.displayName ?? source.filename
                return components[2] == FilenameEscaping.byNameSourceFilename(
                    filename: humanName,
                    ext: source.ext,
                    sourceID: source.id)
            }
            return matches.count == 1 ? matches[0].id : nil
        }
        if components.first == "bookmarks" {
            return bookmarkSourceID(
                components: Array(components.dropFirst()),
                sourcesByID: sourcesByID,
                nodes: bookmarkNodes)
        }
        return nil
    }

    /// File Provider links can be relative to a projected page directory. Drop
    /// only a leading relative prefix and keep the rooted path exact.
    private static func rootedComponents(for path: String) -> [String]? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.isEmpty == false, components[0].isEmpty == false else { return nil }
        var rootIndex = 0
        while rootIndex < components.count,
              components[rootIndex] == "." || components[rootIndex] == ".." {
            rootIndex += 1
        }
        guard rootIndex < components.count,
              components[rootIndex] == "sources" || components[rootIndex] == "bookmarks"
        else { return nil }
        let rooted = Array(components[rootIndex...])
        guard rooted.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else { return nil }
        return rooted
    }

    private static func bookmarkSourceID(
        components: [String],
        sourcesByID: [SourceID: SourceSummary],
        nodes: [BookmarkNode]
    ) -> SourceID? {
        guard let leaf = components.last else { return nil }
        var parentID: BookmarkID?
        for folderName in components.dropLast() {
            let matches = nodes.filter { node in
                node.parentID == parentID
                    && node.kind == .folder
                    && sanitize(node.label ?? "Untitled") == folderName
            }
            guard matches.count == 1 else { return nil }
            parentID = matches[0].id
        }
        let matches = nodes.compactMap { node -> SourceID? in
            guard node.parentID == parentID,
                  case .source(let sourceID) = node.content,
                  let source = sourcesByID[sourceID],
                  sanitize(source.displayName ?? source.filename) == leaf
            else { return nil }
            return sourceID
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
    }
}

/// Immutable image routing for one Markdown document. It accepts only exact
/// sibling-map keys or File Provider paths already resolved to typed source IDs.
enum MarkdownImageTargetProjection {
    static func build(
        siblingSources: [String: RendererEmbeddedContent.Source],
        siblingSourceIDs: [String: SourceID],
        registry: RendererRegistrySnapshot,
        inlineCapableReferences: Set<RendererReference>
    ) throws -> [String: ResolvedMarkdownImageTarget] {
        var targets = [String: ResolvedMarkdownImageTarget]()
        for (target, sourceID) in siblingSourceIDs where isRelativeSiblingTarget(target) {
            targets[target] = .blob(sourceID)
        }
        for (target, source) in siblingSources {
            guard isRelativeSiblingTarget(target),
                  source.bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount,
                  let descriptor = try matchingDescriptor(
                      for: source,
                      registry: registry,
                      inlineCapableReferences: inlineCapableReferences)
            else {
                continue
            }
            targets[target] = .renderer(
                rendererReference: descriptor.reference,
                source: source)
        }
        return targets
    }

    private static func matchingDescriptor(
        for source: RendererEmbeddedContent.Source,
        registry: RendererRegistrySnapshot,
        inlineCapableReferences: Set<RendererReference>
    ) throws -> RendererDescriptor? {
        let sniffedBytes = Data(source.bytes.prefix(RendererMatchingLimits.maximumSniffByteCount))
        let input = try RendererMatchInput(
            mimeType: source.mimeType,
            fileExtension: source.fileExtension.flatMap { try RendererFileExtension(validating: $0) },
            sniffedBytes: sniffedBytes,
            sniffedBytesAreComplete: sniffedBytes.count == source.bytes.count,
            artifactKind: nil)
        return registry.matching(input, requiredEmbeddingRole: .inlineContent).first { descriptor in
            inlineCapableReferences.contains(descriptor.reference) &&
                descriptor.capabilities.contains(.inputRead) &&
                descriptor.matchers.contains(where: { matcher in
                    switch matcher {
                    case .normalizedMIME(let claimed):
                        claimed == source.mimeType
                    case .extensionFallback(let claimed):
                        claimed.rawValue == source.fileExtension && source.fileExtension != nil
                    default:
                        false
                    }
                }) &&
                source.bytes.count <= descriptor.sizeLimits.maximumInputByteCount &&
                source.bytes.count <= descriptor.sizeLimits.maximumDecodedByteCount
        }
    }

    private static func isRelativeSiblingTarget(_ target: String) -> Bool {
        guard target.isEmpty == false,
              target.hasPrefix("/") == false,
              target.hasPrefix("#") == false,
              URLComponents(string: target)?.scheme == nil
        else { return false }
        let components = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ $0.isEmpty == false }) else { return false }
        guard components.contains("..") else { return true }
        var rootIndex = 0
        while rootIndex < components.count,
              components[rootIndex] == "." || components[rootIndex] == ".." {
            rootIndex += 1
        }
        guard rootIndex < components.count,
              components[rootIndex] == "sources" || components[rootIndex] == "bookmarks"
        else { return false }
        return components[rootIndex...].allSatisfy({ $0 != "." && $0 != ".." })
    }
}

/// Builds the per-session asset admission allowlist for the revision-5
/// `assetRead` authority from the reference-extractor records and the exact
/// sibling/File Provider projection established for the current page/source.
///
/// This is the concrete WikiFS-side resolver for
/// `RendererAssetAdmissionBuilder`: it consumes the same sibling maps as the
/// image embed projection (never a loose all-sources lookup), requires a
/// UNIQUE match, and pins the active `SourceVersionID` + MIME + size + digest
/// before session creation. No production branch here names a specific canvas
/// format (or any package); the input is only validated relative references
/// and the declared role set.
enum RendererAssetAdmissionProjection {
    /// Resolve extractor records into exact pinned admissions.
    ///
    /// - Parameters:
    ///   - records: validated `{role, reference}` records from the
    ///     reference-extractor helper.
    ///   - siblingSourceMap: the established sibling/File Provider projection
    ///     (`[relativeKey: SourceID]`) for this page/source context.
    ///   - store: the wiki store used to pin active versions.
    ///   - sourceExtensions: `[SourceID: String]` extension map for MIME.
    ///   - allowedRoles: the declared asset roles (imageNode/groupBackground).
    ///   - maximumBytesPerAsset: the declared per-asset byte cap.
    /// - Returns: the immutable allowlist for the session's
    ///   `RendererAuthorizedAssetReader`, or `[]` when nothing resolves
    ///   (the caller fails closed to non-image rendering + source/raw
    ///   fallback).
    static func buildAdmissions(
        records: [RendererAssetReferenceExtractorClient.ExtractedRecord],
        siblingSourceMap: [String: SourceID],
        store: any WikiStore,
        sourceExtensions: [SourceID: String],
        allowedRoles: Set<RendererAssetRole>,
        maximumBytesPerAsset: Int
    ) throws -> [RendererAuthorizedAssetReader.Admission] {
        // Normalize the comparison key ONCE at admission. Package requests
        // must match this exact key; no basename-only or extension-stripped
        // fallback for byte reads.
        let normalized: [String: SourceID] = Dictionary(
            uniqueKeysWithValues: siblingSourceMap.map { key, sourceID in
                (key.trimmingCharacters(in: .whitespacesAndNewlines), sourceID)
            })

        func resolveFacts(_ rawReference: String) throws -> (
            sourceID: SourceID,
            sourceVersionID: SourceVersionID,
            mimeType: String,
            byteCount: Int,
            digest: String
        )? {
            guard let sourceID = normalized[rawReference],
                  let version = try store.activeContentVersion(sourceID: sourceID)
            else { return nil }
            // A failed source read means the admission is simply unavailable
            // (the reference falls back) — it is not a crash. `try?` is
            // intentional; the caller does not need a typed denial here.
            // swiftlint:disable:next silent_try_optional
            guard let bytes = try? store.sourceContent(versionID: version.id) else { return nil }
            let extensionKey = sourceExtensions[sourceID]
            let mime = version.mimeType ?? Self.mimeType(for: extensionKey)
            return (
                sourceID: sourceID,
                sourceVersionID: version.id,
                mimeType: mime,
                byteCount: bytes.count,
                digest: RendererSHA256.digest(bytes).hex)
        }

        return try RendererAssetAdmissionBuilder.buildAdmissions(
            records: records,
            resolveSourceFacts: resolveFacts,
            allowedRoles: allowedRoles,
            maximumBytesPerAsset: maximumBytesPerAsset)
    }

    private static func mimeType(for fileExtension: String?) -> String {
        switch fileExtension?.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }
}

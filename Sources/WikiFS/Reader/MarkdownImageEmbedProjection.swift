import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core — deterministic projection from pinned source facts.

/// Immutable renderer plans for exact source IDs already resolved from typed
/// wiki embed syntax. Matching stays role-aware and fail-closed.
enum DocumentSourceRendererProjection {
    static func hasEligibleRenderer(
        mimeType: String?,
        registry: RendererRegistrySnapshot,
        inlineCapableReferences: Set<RendererReference>
    ) -> Bool {
        guard let mimeType else { return false }
        let normalizedMIME: RendererMIMEType
        do {
            normalizedMIME = try RendererMIMEType(validating: mimeType)
        } catch {
            DebugLog.reader("Source renderer projection rejected an invalid MIME type.")
            return false
        }
        return registry.descriptors.contains { descriptor in
            descriptor.compatibility.supports(hostProtocolRevision: registry.hostProtocolRevision) &&
                descriptor.supportedEmbeddingRoles.contains(.inlineContent) &&
                inlineCapableReferences.contains(descriptor.reference) &&
                descriptor.capabilities.contains(.inputRead) &&
                descriptor.matchers.contains(.normalizedMIME(normalizedMIME))
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
            fileExtension: nil,
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

/// Immutable image routing for one Markdown document. It accepts only exact
/// sibling-map keys already resolved by the source index. Raw image paths never
/// select a renderer on their own.
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
            fileExtension: nil,
            sniffedBytes: sniffedBytes,
            sniffedBytesAreComplete: sniffedBytes.count == source.bytes.count,
            artifactKind: nil)
        return registry.matching(input, requiredEmbeddingRole: .inlineContent).first { descriptor in
            inlineCapableReferences.contains(descriptor.reference) &&
                descriptor.capabilities.contains(.inputRead) &&
                descriptor.matchers.contains(.normalizedMIME(source.mimeType)) &&
                source.bytes.count <= descriptor.sizeLimits.maximumInputByteCount &&
                source.bytes.count <= descriptor.sizeLimits.maximumDecodedByteCount
        }
    }

    private static func isRelativeSiblingTarget(_ target: String) -> Bool {
        guard target.isEmpty == false,
              target.hasPrefix("/") == false,
              target.hasPrefix("#") == false,
              URLComponents(string: target)?.scheme == nil,
              target.split(separator: "/").contains("..") == false
        else { return false }
        return true
    }
}

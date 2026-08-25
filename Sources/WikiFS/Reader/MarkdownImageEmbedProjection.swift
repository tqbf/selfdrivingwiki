import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core — deterministic projection from pinned source facts.

/// Immutable image routing for one Markdown document. It accepts only exact
/// sibling-map keys already resolved by the source index; raw image paths never
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

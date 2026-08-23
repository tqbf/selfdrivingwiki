import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core — deterministic projection from pinned source facts.

/// Immutable image routing for one Markdown document. It accepts only exact
/// sibling-map keys already resolved by the source index; raw image paths never
/// select a renderer on their own.
struct MarkdownImageEmbedProjection: Sendable {
    struct InteractiveCandidate: Hashable, Sendable {
        let rendererReference: RendererReference
        let source: RendererEmbeddedContent.Source
    }

    enum Outcome: Hashable, Sendable {
        case ordinary
        case interactive(InteractiveCandidate)
    }

    private let outcomes: [String: Outcome]

    init(
        siblingSources: [String: RendererEmbeddedContent.Source],
        registry: RendererRegistrySnapshot,
        inlineCapableReferences: Set<RendererReference>
    ) throws {
        var outcomes = [String: Outcome]()
        for (target, source) in siblingSources {
            guard Self.isRelativeSiblingTarget(target),
                  source.bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount,
                  let descriptor = try Self.matchingDescriptor(
                      for: source,
                      registry: registry,
                      inlineCapableReferences: inlineCapableReferences)
            else {
                continue
            }
            outcomes[target] = .interactive(.init(
                rendererReference: descriptor.reference,
                source: source))
        }
        self.outcomes = outcomes
    }

    func outcome(for rawTarget: String) -> Outcome {
        guard Self.isRelativeSiblingTarget(rawTarget) else { return .ordinary }
        return outcomes[rawTarget] ?? .ordinary
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
        return registry.matching(input).first { descriptor in
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

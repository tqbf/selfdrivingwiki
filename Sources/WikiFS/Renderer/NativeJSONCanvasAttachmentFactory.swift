#if os(macOS)
import Foundation
import SwiftUI
import WikiFSTypes

// pattern: Mixed (unavoidable)
// Reason: The pure authorization and decoding core returns a JSONCanvasDocument;
// the final method is the narrow SwiftUI adapter that constructs its native view.

/// One exact source-version identity authorized for a native JSON Canvas attachment.
/// This deliberately retains no bytes: only the injected resolver may supply them.
enum NativeJSONCanvasAttachmentInput: Equatable, Sendable {
    struct SourcePin: Equatable, Sendable {
        enum Version: Equatable, Sendable {
            case content(SourceVersionID)
            case markdown(SourceMarkdownVersionID)
        }

        let sourceID: SourceID
        let version: Version
        let mimeType: RendererMIMEType
        let digest: RendererSHA256Digest

        init(validating source: RendererEmbeddedContent.Source) throws {
            switch (source.sourceVersionID, source.sourceMarkdownVersionID) {
            case let (.some(versionID), .none):
                version = .content(versionID)
            case let (.none, .some(versionID)):
                version = .markdown(versionID)
            default:
                throw NativeJSONCanvasAttachmentFailure.invalidSourceIdentity
            }
            sourceID = source.sourceID
            mimeType = source.mimeType
            digest = source.digest
        }
    }

    case source(SourcePin)
    case fenced(RendererEmbeddedContent.InlineArtifact)
}

enum NativeJSONCanvasAttachmentFailure: Error, Equatable {
    enum SourceReason: Equatable {
        case invalidMIMEType
        case resolverUnavailable
        case digestMismatch
        case oversizedInput
        case decoding(JSONCanvasDecodingError)
    }

    enum FencedReason: Equatable {
        case invalidFenceKind
        case invalidMIMEType
        case invalidArtifact
        case oversizedInput
        case decoding(JSONCanvasDecodingError)
    }

    case invalidSourceIdentity
    case source(input: NativeJSONCanvasAttachmentInput.SourcePin, reason: SourceReason)
    case fenced(input: RendererEmbeddedContent.InlineArtifact, reason: FencedReason)
}

/// Creates a bounded native JSON Canvas document from one typed authorization form.
/// A source-capable factory is keyed by `SourcePin` rather than a live source.
struct NativeJSONCanvasAttachmentFactory {
    typealias SourceResolver = (NativeJSONCanvasAttachmentInput.SourcePin) throws -> Data

    private let resolveSource: SourceResolver?

    init(_ resolveSource: @escaping SourceResolver) {
        self.resolveSource = resolveSource
    }

    /// Creates a factory for fenced inline artifacts only. It intentionally has
    /// no source resolver, so future source-pin routing cannot use this path.
    static func fencedOnly() -> Self {
        Self(resolveSource: nil)
    }

    private init(resolveSource: SourceResolver?) {
        self.resolveSource = resolveSource
    }

    func document(for input: NativeJSONCanvasAttachmentInput) throws -> JSONCanvasDocument {
        switch input {
        case .source(let pin):
            return try document(for: pin)
        case .fenced(let artifact):
            return try document(for: artifact)
        }
    }

    @MainActor
    func makeView(
        for input: NativeJSONCanvasAttachmentInput,
        onHostAction: @escaping (JSONCanvasHostAction) -> Void = { _ in },
        onInteractionChange: @escaping (JSONCanvasInteractionSnapshot) -> Void = { _ in }
    ) throws -> AnyView {
        AnyView(JSONCanvasRendererView(
            document: try document(for: input),
            presentation: .inlineAttachment,
            onHostAction: onHostAction,
            onInteractionChange: onInteractionChange))
    }

    private func document(for pin: NativeJSONCanvasAttachmentInput.SourcePin) throws -> JSONCanvasDocument {
        guard pin.mimeType.rawValue == BuiltInRendererMIME.json else {
            throw NativeJSONCanvasAttachmentFailure.source(input: pin, reason: .invalidMIMEType)
        }
        guard let resolveSource else {
            throw NativeJSONCanvasAttachmentFailure.source(input: pin, reason: .resolverUnavailable)
        }
        let bytes: Data
        do {
            bytes = try resolveSource(pin)
        } catch {
            throw NativeJSONCanvasAttachmentFailure.source(input: pin, reason: .resolverUnavailable)
        }
        guard bytes.count <= JSONCanvasLimits.maximumInputByteCount else {
            throw NativeJSONCanvasAttachmentFailure.source(input: pin, reason: .oversizedInput)
        }
        guard RendererSHA256.digest(bytes) == pin.digest else {
            throw NativeJSONCanvasAttachmentFailure.source(input: pin, reason: .digestMismatch)
        }
        do {
            return try JSONCanvasDocument.decode(bytes)
        } catch let error as JSONCanvasDecodingError {
            throw NativeJSONCanvasAttachmentFailure.source(input: pin, reason: .decoding(error))
        } catch {
            throw NativeJSONCanvasAttachmentFailure.source(input: pin, reason: .decoding(.malformedDocument))
        }
    }

    private func document(for artifact: RendererEmbeddedContent.InlineArtifact) throws -> JSONCanvasDocument {
        guard artifact.fenceKind == .jsoncanvas else {
            throw NativeJSONCanvasAttachmentFailure.fenced(input: artifact, reason: .invalidFenceKind)
        }
        guard artifact.mimeType.rawValue == BuiltInRendererMIME.json else {
            throw NativeJSONCanvasAttachmentFailure.fenced(input: artifact, reason: .invalidMIMEType)
        }
        do {
            _ = try RendererEmbeddedContent.InlineArtifact(
                pageID: artifact.pageID,
                pageVersionID: artifact.pageVersionID,
                blockID: artifact.blockID,
                fenceKind: artifact.fenceKind,
                mimeType: artifact.mimeType,
                bytes: artifact.bytes)
        } catch {
            throw NativeJSONCanvasAttachmentFailure.fenced(input: artifact, reason: .invalidArtifact)
        }
        guard artifact.bytes.count <= JSONCanvasLimits.maximumInputByteCount else {
            throw NativeJSONCanvasAttachmentFailure.fenced(input: artifact, reason: .oversizedInput)
        }
        do {
            return try JSONCanvasDocument.decode(artifact.bytes)
        } catch let error as JSONCanvasDecodingError {
            throw NativeJSONCanvasAttachmentFailure.fenced(input: artifact, reason: .decoding(error))
        } catch {
            throw NativeJSONCanvasAttachmentFailure.fenced(input: artifact, reason: .decoding(.malformedDocument))
        }
    }
}
#endif

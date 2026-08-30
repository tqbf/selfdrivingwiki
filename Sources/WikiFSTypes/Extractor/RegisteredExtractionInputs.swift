import Foundation

// pattern: Functional Core

/// The input surface an ACTIVE extractor registration declares: which MIME
/// types and filename extensions each registered extractor kind accepts.
///
/// This is the value that makes package registrations RECOGNIZE content at
/// ingestion. A manifest that declares `filenameExtensions: ["docx"]` and
/// the wordprocessingml MIME is not just Settings presentation — it is the
/// declaration that files of that shape have an extraction path. Ingestion
/// consults this surface so a `.docx` (whose bytes are a generic ZIP
/// container the byte sniffer cannot distinguish from any other archive)
/// classifies as the registered Word type and flows to extraction
/// automatically.
///
/// Pure value, built by the engine from the live registry
/// (`ExtractionBackendRegistry.registeredExtractionInputs()`) and injected
/// into the store/model so classification stays a leaf-type decision with
/// no engine dependency. `.none` (the default) preserves the pre-registration
/// behavior everywhere the surface is not wired.
public struct RegisteredExtractionInputs: Hashable, Sendable {
    /// Registered input MIME types by extractor kind (lowercased).
    public let mimeTypes: Set<RegisteredMIME>
    /// Registered filename extensions by extractor kind (lowercased, no dot).
    public let filenameExtensions: Set<RegisteredExtension>

    public init(
        mimeTypes: Set<RegisteredMIME> = [],
        filenameExtensions: Set<RegisteredExtension> = []
    ) {
        self.mimeTypes = mimeTypes
        self.filenameExtensions = filenameExtensions
    }

    public static let none = RegisteredExtractionInputs()

    public var isEmpty: Bool { mimeTypes.isEmpty && filenameExtensions.isEmpty }

    /// One registered input MIME type.
    public struct RegisteredMIME: Hashable, Sendable, CustomStringConvertible {
        public let kind: ExtractorKind
        public let mimeType: String

        public init(kind: ExtractorKind, mimeType: String) {
            self.kind = kind
            self.mimeType = mimeType.lowercased()
        }

        public var description: String { "\(kind.rawValue) \(mimeType)" }
    }

    /// One registered filename extension.
    public struct RegisteredExtension: Hashable, Sendable, CustomStringConvertible {
        public let kind: ExtractorKind
        public let ext: String

        public init(kind: ExtractorKind, ext: String) {
            self.kind = kind
            self.ext = ext.lowercased()
        }

        public var description: String { "\(kind.rawValue) .\(ext)" }
    }

    /// The registered MIME for a normalized lowercase MIME type, if an
    /// active registration declares it.
    public func registeredMIME(forNormalizedMIME mime: String) -> RegisteredMIME? {
        mimeTypes.first { $0.mimeType == mime.lowercased() }
    }

    /// The registered input for a lowercased filename extension (no dot),
    /// if an active registration declares it.
    public func registeredInput(forNormalizedExtension ext: String) -> RegisteredExtension? {
        filenameExtensions.first { $0.ext == ext.lowercased() }
    }

    /// Registration-driven promotion for a generic container sniff.
    ///
    /// Some registered inputs ARE archive containers (a `.docx` is a ZIP),
    /// so the byte sniffer resolves them to `application/zip` — a type with
    /// no extraction path. When an active registration declares the file's
    /// extension (or its declared MIME) as its input, the registration wins:
    /// the registered MIME is what ingestion should record. This is the
    /// "the package recognizes word documents" rule — recognition comes
    /// from the registration, not from a hardcoded byte or name table.
    ///
    /// Returns nil when the detected type is not a generic container or no
    /// active registration claims the file, leaving detection unchanged.
    public func promotedMIME(
        detectedMIME: String?,
        declaredMIME: String?,
        filenameExtension ext: String?
    ) -> String? {
        guard detectedMIME?.lowercased() == MimeType.zip else { return nil }
        if let declaredMIME, let registered = registeredMIME(forNormalizedMIME: declaredMIME) {
            return registered.mimeType
        }
        if let ext,
           let registered = registeredInput(forNormalizedExtension: ext),
           // The same registry fold carries the kind's declared MIME types;
           // pick one deterministically.
           let mime = mimeTypes
               .filter({ $0.kind == registered.kind })
               .sorted(by: { $0.mimeType < $1.mimeType })
               .first {
            return mime.mimeType
        }
        return nil
    }
}

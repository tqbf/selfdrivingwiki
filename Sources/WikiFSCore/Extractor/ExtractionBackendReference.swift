import Foundation
import WikiFSTypes
import WikiFSMarkdown

/// Stable identity for one host-owned extraction adapter.
///
/// The route supplies the input kind and MIME type. This identity therefore
/// names only the host adapter and never embeds PDF, HTML, or DOCX knowledge.
public struct HostExtractorID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.isEmpty == false,
              rawValue.utf8.count <= 128,
              rawValue.contains("/") == false,
              rawValue.contains("\\") == false,
              rawValue.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw ExtractorValidationError.invalidIdentifier(kind: "host extractor ID", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(validating: String(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Host-owned adapter identity. The route record stores this value without
/// knowing which input format the adapter handles.
public struct HostExtractorReference: Codable, Hashable, Sendable, Comparable {
    public let adapterID: HostExtractorID

    public init(adapterID: HostExtractorID) {
        self.adapterID = adapterID
    }

    public init(validatingAdapterID rawValue: String) throws {
        self.init(adapterID: try HostExtractorID(validating: rawValue))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.adapterID < rhs.adapterID
    }
}

/// Persisted, version-free extractor selection for one route.
///
/// The route supplies the input domain. A selection names either a host adapter,
/// an installed package lineage, or an explicit override that disables the
/// shipped default. New configuration never stores format-specific cases.
public enum ExtractionBackendReference: Codable, Hashable, Sendable {
    /// Explicitly disables the shipped default for this route.
    case none
    case host(HostExtractorReference)
    case installed(LogicalExtractorReference)

    private enum CodingKeys: String, CodingKey { case kind, host, installed, builtIn }
    private enum Kind: String, Codable { case none, host, installed, builtIn }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .host:
            self = .host(try container.decode(HostExtractorReference.self, forKey: .host))
        case .installed:
            self = .installed(try container.decode(LogicalExtractorReference.self, forKey: .installed))
        case .builtIn:
            // Route records from the earlier branch used typed PDF/HTML values.
            // Decode them once, then keep only the generic host identity.
            let legacy = try container.decode(LegacyBuiltInReference.self, forKey: .builtIn)
            self = .host(legacy.hostReference)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .host(let reference):
            try container.encode(Kind.host, forKey: .kind)
            try container.encode(reference, forKey: .host)
        case .installed(let reference):
            try container.encode(Kind.installed, forKey: .kind)
            try container.encode(reference, forKey: .installed)
        }
    }
}

/// Decode-only compatibility for route records written by the earlier branch.
/// No production selection API exposes this format-specific representation.
private enum LegacyBuiltInReference: Codable {
    case pdf(ExtractionBackend)
    case html(HtmlExtractionBackend)

    private enum CodingKeys: String, CodingKey { case kind, backend }
    private enum Kind: String, Codable { case pdf, html }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pdf: self = .pdf(try container.decode(ExtractionBackend.self, forKey: .backend))
        case .html: self = .html(try container.decode(HtmlExtractionBackend.self, forKey: .backend))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pdf(let backend):
            try container.encode(Kind.pdf, forKey: .kind)
            try container.encode(backend, forKey: .backend)
        case .html(let backend):
            try container.encode(Kind.html, forKey: .kind)
            try container.encode(backend, forKey: .backend)
        }
    }

    var hostReference: HostExtractorReference {
        let rawValue: String
        switch self {
        case .pdf(let backend): rawValue = backend.rawValue
        case .html(let backend): rawValue = backend.rawValue
        }
        guard let adapterID = HostExtractorID(rawValue: rawValue) else {
            preconditionFailure("Legacy built-in backend has an invalid host adapter ID")
        }
        return HostExtractorReference(adapterID: adapterID)
    }
}

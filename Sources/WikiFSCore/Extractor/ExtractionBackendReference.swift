import Foundation
import WikiFSTypes
import WikiFSMarkdown

/// Persisted, version-free PDF or HTML extractor selection.
public enum ExtractionBackendReference: Codable, Hashable, Sendable {
    case builtIn(BuiltInExtractionReference)
    case installed(LogicalExtractorReference)

    private enum CodingKeys: String, CodingKey { case kind, builtIn, installed }
    private enum Kind: String, Codable { case builtIn, installed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .builtIn:
            self = .builtIn(try container.decode(BuiltInExtractionReference.self, forKey: .builtIn))
        case .installed:
            self = .installed(try container.decode(LogicalExtractorReference.self, forKey: .installed))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn(let reference):
            try container.encode(Kind.builtIn, forKey: .kind)
            try container.encode(reference, forKey: .builtIn)
        case .installed(let reference):
            try container.encode(Kind.installed, forKey: .kind)
            try container.encode(reference, forKey: .installed)
        }
    }
}

/// Host-owned built-in selection. The case tag keeps PDF and HTML namespaces distinct.
public enum BuiltInExtractionReference: Codable, Hashable, Sendable {
    case pdf(ExtractionBackend)
    case html(HtmlExtractionBackend)

    private enum CodingKeys: String, CodingKey { case kind, backend }
    private enum Kind: String, Codable { case pdf, html }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pdf: self = .pdf(try container.decode(ExtractionBackend.self, forKey: .backend))
        case .html: self = .html(try container.decode(HtmlExtractionBackend.self, forKey: .backend))
        }
    }

    public func encode(to encoder: any Encoder) throws {
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
}

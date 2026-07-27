import Foundation
import WikiFSTypes

public enum OKFConceptType: String, Sendable {
    case page = "Page"
    case source = "Source"
}

public struct OKFActor: Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(pageAuthorRawValue: String?) {
        self = Self.pageActor(from: PageAuthor(rawValue: pageAuthorRawValue))
    }

    public static func pageActor(from author: PageAuthor) -> OKFActor {
        switch author {
        case .user:
            return OKFActor(rawValue: "human:user")
        case .chat(let id):
            return OKFActor(rawValue: "process:chat:\(id)")
        case .agent(let kind):
            return OKFActor(rawValue: "process:agent:\(kind)")
        case .legacyImport:
            return OKFActor(rawValue: "process:legacy-import")
        case .other(let rawValue):
            return Self.normalizedProducer(rawName: rawValue, version: nil)
        }
    }

    public static func sourceActor(
        producerName: String?,
        producerVersion: String?,
        fallbackOrigin: SourceMarkdownOrigin
    ) -> OKFActor {
        if let producerName, !producerName.isEmpty {
            return normalizedProducer(rawName: producerName, version: producerVersion)
        }

        switch fallbackOrigin {
        case .user:
            return OKFActor(rawValue: "human:user")
        case .revert:
            return OKFActor(rawValue: "process:revert")
        case .source:
            return OKFActor(rawValue: "process:source")
        case .transcript:
            return OKFActor(rawValue: "process:transcript")
        case .extraction:
            return OKFActor(rawValue: "process:extraction")
        }
    }

    private static func normalizedProducer(rawName: String, version: String?) -> OKFActor {
        if rawName.hasPrefix("human:") || rawName.hasPrefix("process:") || rawName.contains("/") {
            return OKFActor(rawValue: rawName)
        }
        if rawName == PageAuthor.user.rawValue {
            return OKFActor(rawValue: "human:user")
        }
        if let version, !version.isEmpty {
            return OKFActor(rawValue: "\(rawName)/\(version)")
        }
        return OKFActor(rawValue: "process:\(rawName)")
    }
}

public struct OKFGenerated: Equatable, Sendable {
    public let by: OKFActor
    public let at: Date

    public init(by: OKFActor, at: Date) {
        self.by = by
        self.at = at
    }
}

public enum OKFResource: Equatable, Sendable {
    case url(URL)
    case bundlePath(String)

    var scalarValue: String {
        switch self {
        case .url(let url):
            return url.absoluteString
        case .bundlePath(let path):
            return path
        }
    }
}

public struct OKFSourceReference: Equatable, Sendable {
    public let resource: OKFResource
    public let title: String?

    public init(resource: OKFResource, title: String? = nil) {
        self.resource = resource
        self.title = title
    }
}

public struct PageOKFMetadata: Equatable, Sendable {
    public let generated: OKFGenerated
    public let sources: [OKFSourceReference]

    public init(generated: OKFGenerated, sources: [OKFSourceReference] = []) {
        self.generated = generated
        self.sources = sources
    }
}

public struct SourceOKFMetadata: Equatable, Sendable {
    public let title: String
    public let generated: OKFGenerated
    public let sources: [OKFSourceReference]

    public init(title: String, generated: OKFGenerated, sources: [OKFSourceReference]) {
        self.title = title
        self.generated = generated
        self.sources = sources
    }
}

enum OKFFrontmatter {
    static func concept(
        type: OKFConceptType,
        title: String,
        generated: OKFGenerated,
        sources: [OKFSourceReference]
    ) -> String {
        var lines = [
            "type: \(yamlString(type.rawValue))",
            "title: \(yamlString(title))",
            "generated:",
            "  by: \(yamlString(generated.by.rawValue))",
            "  at: \(iso8601(generated.at))"
        ]

        if !sources.isEmpty {
            lines.append("sources:")
            for source in sources {
                lines.append("  - resource: \(yamlString(source.resource.scalarValue))")
                if let title = source.title {
                    lines.append("    title: \(yamlString(title))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    static func rootIndex(body: String) -> String {
        let stripped = stripLeadingFrontmatter(from: body)
        return """
        ---
        okf_version: "0.2"
        ---

        \(stripped)
        """
    }

    private static func stripLeadingFrontmatter(from body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return body
        }

        var index = 1
        while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces) != "---" {
            index += 1
        }
        if index < lines.count {
            index += 1
        }
        while index < lines.count && lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
        return lines[index...].joined(separator: "\n")
    }

    private static func yamlString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public enum OKFRootIndexFormat {
    public static func fileContent(body: String) -> String {
        OKFFrontmatter.rootIndex(body: body)
    }
}

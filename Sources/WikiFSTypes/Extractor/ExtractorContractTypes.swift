import Foundation

// pattern: Functional Core

public enum ExtractorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case pdf
    case html
}

public enum ExtractorLaunchMode: String, Codable, CaseIterable, Hashable, Sendable {
    case direct
    case runtime
}

public enum ExtractorCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case network
    case sharedRuntimeCache = "shared-runtime-cache"
    case modelDownload = "model-download"
}

public enum ExtractorInputTransport: String, Codable, CaseIterable, Hashable, Sendable {
    case operationFile = "operation-file"
}

public enum ExtractorEventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case progress
    case diagnostic
    case result
    case failure
}

public enum ExtractorFailureCause: String, Codable, CaseIterable, Hashable, Sendable {
    case unsupportedInput = "unsupported-input"
    case invalidRequest = "invalid-request"
    case missingRuntime = "missing-runtime"
    case setup
    case timeout
    case cancellation
    case processTermination = "process-termination"
    case outputLimit = "output-limit"
    case malformedProtocol = "malformed-protocol"
    case extractionFailure = "extraction-failure"
}

/// One command name. Host policy resolves this name against an immutable search list.
public struct ExtractorRuntimeName: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.isEmpty == false,
              rawValue.count <= 128,
              rawValue.contains("/") == false,
              rawValue.contains("\\") == false,
              rawValue.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_+.".contains($0)) })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw ExtractorValidationError.invalidIdentifier(kind: "extractor runtime name", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ExtractorMIMEType: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue == rawValue.lowercased(),
              rawValue.range(
                of: "^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$",
                options: .regularExpression) != nil
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw ExtractorValidationError.invalidIdentifier(kind: "extractor MIME type", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ExtractorFileExtension: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue == rawValue.lowercased(),
              rawValue.isEmpty == false,
              rawValue.count <= 32,
              rawValue.hasPrefix(".") == false,
              rawValue.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw ExtractorValidationError.invalidIdentifier(kind: "extractor file extension", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A validated package-relative path. Validation rejects traversal instead of normalizing it.
public struct ExtractorRelativePath: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        let segments = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard rawValue.isEmpty == false,
              rawValue.hasPrefix("/") == false,
              rawValue.contains("\\") == false,
              segments.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." && $0.contains("\0") == false })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else { throw ExtractorValidationError.invalidPath(rawValue) }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    /// Stable collision key for package admission on case-insensitive, Unicode-normalizing filesystems.
    public var collisionKey: String {
        rawValue.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

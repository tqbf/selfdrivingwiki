import Foundation

/// A structured content kind that byte ingestion and renderer matching can share.
public enum ContentArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case jsonCanvas
}

/// A bounded artifact-validation input. Callers state completeness explicitly.
public struct BoundedArtifactInput: Hashable, Sendable {
    public let bytes: Data
    public let isComplete: Bool

    public init(bytes: Data, isComplete: Bool) {
        self.bytes = Data(bytes.prefix(ContentArtifactValidationLimits.maximumInputByteCount))
        self.isComplete = isComplete && bytes.count <= ContentArtifactValidationLimits.maximumInputByteCount
    }
}

public enum ContentArtifactValidationLimits {
    public static let maximumInputByteCount = 64 * 1_024
}

/// Fail-closed structural validation for host-native structured artifacts.
public enum ContentArtifactValidator {
    public static func matches(_ kind: ContentArtifactKind, input: BoundedArtifactInput) -> Bool {
        guard input.isComplete else { return false }
        switch kind {
        case .jsonCanvas:
            do {
                _ = try JSONDecoder().decode(JSONCanvasSignature.self, from: input.bytes)
                return true
            } catch {
                return false
            }
        }
    }
}

// pattern: Functional Core

public struct RendererSignature: Codable, Hashable, Sendable {
    public let offset: Int
    public let bytes: [UInt8]

    public init(offset: Int, bytes: [UInt8]) throws {
        guard offset >= 0, bytes.isEmpty == false,
              offset <= RendererMatchingLimits.maximumSniffByteCount,
              bytes.count <= RendererMatchingLimits.maximumSniffByteCount - offset else {
            throw RendererValidationError.invalidSignature
        }
        self.offset = offset
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(offset: container.decode(Int.self, forKey: .offset), bytes: container.decode([UInt8].self, forKey: .bytes))
    }
}

/// A bounded, manifest-declared JSON root constraint. The matcher checks only
/// the complete root object and the named properties and arrays in this value.
/// It does not walk nested data or execute package code.
public struct RendererJSONConstraints: Codable, Hashable, Sendable {
    public enum Root: String, Codable, Hashable, Sendable {
        case object
    }

    public enum Scalar: Codable, Hashable, Sendable {
        case stringEquals(String)
        case integerEquals(Int)

        private enum CodingKeys: String, CodingKey {
            case stringEquals
            case integerEquals
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.allKeys.count == 1 else {
                throw RendererValidationError.invalidJSONMatcher
            }
            if container.contains(.stringEquals) {
                self = .stringEquals(try container.decode(String.self, forKey: .stringEquals))
            } else if container.contains(.integerEquals) {
                self = .integerEquals(try container.decode(Int.self, forKey: .integerEquals))
            } else {
                throw RendererValidationError.invalidJSONMatcher
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .stringEquals(value): try container.encode(value, forKey: .stringEquals)
            case let .integerEquals(value): try container.encode(value, forKey: .integerEquals)
            }
        }
    }

    public enum ArrayElement: String, Codable, Hashable, Sendable {
        case object
    }

    public let root: Root
    public let properties: [String: Scalar]
    public let arrays: [String: ArrayElement]

    public init(
        root: Root = .object,
        properties: [String: Scalar] = [:],
        arrays: [String: ArrayElement] = [:]
    ) throws {
        guard properties.count <= Limits.maximumConstraintCount,
              arrays.count <= Limits.maximumConstraintCount,
              properties.keys.allSatisfy(Self.isValidKey),
              arrays.keys.allSatisfy(Self.isValidKey),
              Set(properties.keys).isDisjoint(with: arrays.keys),
              properties.values.allSatisfy(Self.isValidScalar),
              properties.values.compactMap(Self.stringValue).allSatisfy({ $0.utf8.count <= Limits.maximumStringLength }) else {
            throw RendererValidationError.invalidJSONMatcher
        }
        self.root = root
        self.properties = properties
        self.arrays = arrays
        self.wireFormat = .current
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case properties
        case arrays
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.allSatisfy({ [.root, .properties, .arrays].contains($0) }) else {
            throw RendererValidationError.invalidJSONMatcher
        }
        try self.init(
            root: try container.decode(Root.self, forKey: .root),
            properties: try container.decodeIfPresent([String: Scalar].self, forKey: .properties) ?? [:],
            arrays: try container.decodeIfPresent([String: ArrayElement].self, forKey: .arrays) ?? [:],
            wireFormat: .current)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(properties, forKey: .properties)
        try container.encode(arrays, forKey: .arrays)
    }

    private enum Limits {
        static let maximumConstraintCount = 32
        static let maximumKeyLength = 64
        static let maximumStringLength = 256
    }

    private static func isValidKey(_ key: String) -> Bool {
        key.isEmpty == false && key.utf8.count <= Limits.maximumKeyLength
    }

    private static func isValidScalar(_ scalar: Scalar) -> Bool {
        switch scalar {
        case .stringEquals, .integerEquals: true
        }
    }

    private static func stringValue(_ scalar: Scalar) -> String? {
        guard case let .stringEquals(value) = scalar else { return nil }
        return value
    }

    public func matches(sniffedBytes: Data, isComplete: Bool) -> Bool {
        guard isComplete, sniffedBytes.count <= RendererMatchingLimits.maximumSniffByteCount else {
            return false
        }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(
                with: sniffedBytes,
                options: [.fragmentsAllowed]) as? [String: Any] else {
                return false
            }
            object = decoded
        } catch {
            return false
        }
        guard object.keys.allSatisfy(Self.isValidKey) else { return false }
        for (key, constraint) in properties {
            guard let value = object[key], Self.matches(value: value, constraint: constraint) else {
                return false
            }
        }
        for (key, elementConstraint) in arrays {
            guard let values = object[key] as? [Any],
                  values.allSatisfy({ Self.matches(element: $0, constraint: elementConstraint) }) else {
                return false
            }
        }
        return true
    }

    private static func matches(value: Any, constraint: Scalar) -> Bool {
        switch constraint {
        case let .stringEquals(expected):
            return value as? String == expected
        case let .integerEquals(expected):
            return integerValue(value) == expected
        }
    }

    private static func integerValue(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        guard number.doubleValue == Double(integer),
              integer >= Int64(Int.min), integer <= Int64(Int.max) else { return nil }
        return Int(integer)
    }

    private static func matches(element: Any, constraint: ArrayElement) -> Bool {
        switch constraint {
        case .object:
            guard let object = element as? [String: Any] else { return false }
            return object.keys.allSatisfy(isValidKey)
        }
    }

    fileprivate enum WireFormat: Hashable, Sendable {
        case current
        case legacyBoundedJSONArtifact(String)
    }

    fileprivate let wireFormat: WireFormat

    fileprivate init(
        root: Root,
        properties: [String: Scalar],
        arrays: [String: ArrayElement],
        wireFormat: WireFormat
    ) throws {
        guard properties.count <= Limits.maximumConstraintCount,
              arrays.count <= Limits.maximumConstraintCount,
              properties.keys.allSatisfy(Self.isValidKey),
              arrays.keys.allSatisfy(Self.isValidKey),
              Set(properties.keys).isDisjoint(with: arrays.keys),
              properties.values.allSatisfy(Self.isValidScalar),
              properties.values.compactMap(Self.stringValue).allSatisfy({ $0.utf8.count <= Limits.maximumStringLength }) else {
            throw RendererValidationError.invalidJSONMatcher
        }
        self.root = root
        self.properties = properties
        self.arrays = arrays
        self.wireFormat = wireFormat
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.root == rhs.root && lhs.properties == rhs.properties && lhs.arrays == rhs.arrays
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(root)
        hasher.combine(properties)
        hasher.combine(arrays)
    }
}

public enum RendererMatcher: Codable, Hashable, Sendable {
    case normalizedMIME(RendererMIMEType)
    case extensionFallback(RendererFileExtension)
    case boundedSignature(RendererSignature)
    /// A bounded root-object constraint decoded from manifest data. The
    /// constraint runs before MIME or filename routing, so malformed or
    /// incomplete input remains on Source fallback.
    case boundedJSON(RendererJSONConstraints)
    case artifactKind(RendererArtifactKind)

    private enum CodingKeys: String, CodingKey {
        case normalizedMIME
        case extensionFallback
        case boundedSignature
        case boundedJSON
        // Compatibility token for unchanged machine records from package
        // version 1.0.4. The decoder translates it to generic constraints.
        case boundedJSONArtifact
        case artifactKind
    }

    private enum AssociatedCodingKeys: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw RendererValidationError.invalidJSONMatcher
        }
        switch key {
        case .normalizedMIME:
            self = .normalizedMIME(try Self.decodeAssociated(RendererMIMEType.self, from: container, forKey: key))
        case .extensionFallback:
            self = .extensionFallback(try Self.decodeAssociated(RendererFileExtension.self, from: container, forKey: key))
        case .boundedSignature:
            self = .boundedSignature(try Self.decodeAssociated(RendererSignature.self, from: container, forKey: key))
        case .boundedJSON:
            self = .boundedJSON(try Self.decodeAssociated(RendererJSONConstraints.self, from: container, forKey: key))
        case .boundedJSONArtifact:
            let legacy = try Self.decodeAssociated(String.self, from: container, forKey: key)
            switch legacy {
            case "excalidraw":
                self = .boundedJSON(try RendererJSONConstraints(
                    root: .object,
                    properties: [
                        "type": .stringEquals("excalidraw"),
                        "version": .integerEquals(2),
                    ],
                    arrays: ["elements": .object],
                    wireFormat: .legacyBoundedJSONArtifact(legacy)))
            case "jsonCanvas":
                self = .boundedJSON(try RendererJSONConstraints(
                    root: .object,
                    properties: [:],
                    arrays: ["nodes": .object, "edges": .object],
                    wireFormat: .legacyBoundedJSONArtifact(legacy)))
            default:
                throw RendererValidationError.invalidJSONMatcher
            }
        case .artifactKind:
            self = .artifactKind(try Self.decodeAssociated(RendererArtifactKind.self, from: container, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .normalizedMIME(value): try Self.encodeAssociated(value, into: &container, forKey: .normalizedMIME)
        case let .extensionFallback(value): try Self.encodeAssociated(value, into: &container, forKey: .extensionFallback)
        case let .boundedSignature(value): try Self.encodeAssociated(value, into: &container, forKey: .boundedSignature)
        case let .boundedJSON(value):
            switch value.wireFormat {
            case .current:
                try Self.encodeAssociated(value, into: &container, forKey: .boundedJSON)
            case let .legacyBoundedJSONArtifact(legacy):
                try Self.encodeAssociated(legacy, into: &container, forKey: .boundedJSONArtifact)
            }
        case let .artifactKind(value): try Self.encodeAssociated(value, into: &container, forKey: .artifactKind)
        }
    }

    private static func decodeAssociated<Value: Decodable>(
        _ type: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Value {
        let nested = try container.nestedContainer(keyedBy: AssociatedCodingKeys.self, forKey: key)
        return try nested.decode(Value.self, forKey: .value)
    }

    private static func encodeAssociated<Value: Encodable>(
        _ value: Value,
        into container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        var nested = container.nestedContainer(keyedBy: AssociatedCodingKeys.self, forKey: key)
        try nested.encode(value, forKey: .value)
    }

    public func matches(_ input: RendererMatchInput) -> Bool {
        switch self {
        case let .normalizedMIME(mime): input.mimeType == mime
        case let .extensionFallback(fileExtension): input.fileExtension == fileExtension
        case let .boundedSignature(signature): input.sniffedBytes.matches(signature)
        case let .boundedJSON(constraints):
            constraints.matches(sniffedBytes: input.sniffedBytes, isComplete: input.sniffedBytesAreComplete)
        case let .artifactKind(kind): input.artifactKind == kind
        }
    }

    public var isExtensionFallback: Bool {
        if case .extensionFallback = self { return true }
        return false
    }

    /// JSON validation is a required gate rather than an alternative routing
    /// hint. This preserves Source fallback for malformed files whose MIME type
    /// or extension otherwise looks renderable.
    public var requiresArtifactValidation: Bool {
        if case .boundedJSON = self { return true }
        return false
    }
}

public struct RendererMatchInput: Hashable, Sendable {
    public let mimeType: RendererMIMEType?
    public let fileExtension: RendererFileExtension?
    public let sniffedBytes: Data
    public let sniffedBytesAreComplete: Bool
    public let artifactKind: RendererArtifactKind?

    public init(
        mimeType: RendererMIMEType?,
        fileExtension: RendererFileExtension?,
        sniffedBytes: Data,
        sniffedBytesAreComplete: Bool = true,
        artifactKind: RendererArtifactKind?
    ) throws {
        guard sniffedBytes.count <= RendererMatchingLimits.maximumSniffByteCount else {
            throw RendererValidationError.invalidSizeLimit("sniff byte count \(sniffedBytes.count)")
        }
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.sniffedBytes = sniffedBytes
        self.sniffedBytesAreComplete = sniffedBytesAreComplete
        self.artifactKind = artifactKind
    }
}

private struct JSONCanvasSignature: Decodable {
    let nodes: [JSONObject]
    let edges: [JSONObject]
}

private struct JSONObject: Decodable {
    init(from decoder: any Decoder) throws {
        _ = try decoder.container(keyedBy: JSONKey.self)
    }
}

private struct JSONKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Data {
    func matches(_ signature: RendererSignature) -> Bool {
        let end = signature.offset + signature.bytes.count
        guard count >= end else { return false }
        return Array(self[signature.offset..<end]) == signature.bytes
    }
}

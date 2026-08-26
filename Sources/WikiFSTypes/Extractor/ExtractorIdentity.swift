import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// pattern: Functional Core

public enum ExtractorValidationError: Error, Equatable, Sendable {
    case invalidIdentifier(kind: String, value: String)
    case invalidVersion(String)
    case invalidDigest(String)
    case invalidUUID(String)
    case invalidRevision(Int)
    case invalidPath(String)
    case unsupportedManifestRevision(Int)
    case invalidManifest(String)
    case duplicateRegistration(ExtractorRegistrationID)
    case duplicatePath(ExtractorRelativePath)
    case normalizedPathCollision(ExtractorRelativePath)
    case capabilityRequiresNetwork(ExtractorCapability)
    case limitExceedsHostPolicy(String)
}

/// Stable lineage of one extractor package.
public struct ExtractorPackageID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        let labels = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(ExtractorIdentifierRules.isPackageLabel) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw ExtractorValidationError.invalidIdentifier(kind: "extractor package ID", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Immutable semantic version of an extractor package.
public struct ExtractorPackageVersion: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String
    public let major: UInt
    public let minor: UInt
    public let patch: UInt
    public let prerelease: String?
    public let buildMetadata: String?

    public init?(rawValue: String) {
        let components = rawValue.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let versionAndPrerelease = components[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              let major = ExtractorIdentifierRules.strictUInt(numbers[0]),
              let minor = ExtractorIdentifierRules.strictUInt(numbers[1]),
              let patch = ExtractorIdentifierRules.strictUInt(numbers[2]),
              components.count <= 2,
              components.count == 1 || ExtractorIdentifierRules.isBuildMetadata(String(components[1])),
              versionAndPrerelease.count == 1 || ExtractorIdentifierRules.isPrerelease(String(versionAndPrerelease[1]))
        else { return nil }
        self.rawValue = rawValue
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = versionAndPrerelease.count == 2 ? String(versionAndPrerelease[1]) : nil
        self.buildMetadata = components.count == 2 ? String(components[1]) : nil
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else { throw ExtractorValidationError.invalidVersion(rawValue) }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public func semanticPrecedence(comparedTo other: Self) -> ComparisonResult {
        if major != other.major { return major < other.major ? .orderedAscending : .orderedDescending }
        if minor != other.minor { return minor < other.minor ? .orderedAscending : .orderedDescending }
        if patch != other.patch { return patch < other.patch ? .orderedAscending : .orderedDescending }
        switch (prerelease, other.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, .some): return .orderedDescending
        case (.some, nil): return .orderedAscending
        case let (.some(left), .some(right)): return ExtractorIdentifierRules.comparePrerelease(left, right)
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let precedence = lhs.semanticPrecedence(comparedTo: rhs)
        return precedence == .orderedSame ? lhs.rawValue < rhs.rawValue : precedence == .orderedAscending
    }
}

/// SHA-256 digest with exactly 32 bytes and canonical lowercase hexadecimal encoding.
public struct ExtractorPackageDigest: Codable, Hashable, Sendable, Comparable {
    public static let byteCount = 32
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw ExtractorValidationError.invalidDigest("byte count \(bytes.count)")
        }
        self.bytes = bytes
    }

    public init(hex: String) throws {
        guard hex.count == Self.byteCount * 2 else { throw ExtractorValidationError.invalidDigest(hex) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let pair = hex[index..<next]
            guard pair.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }),
                  let byte = UInt8(pair, radix: 16) else {
                throw ExtractorValidationError.invalidDigest(hex)
            }
            bytes.append(byte)
            index = next
        }
        try self.init(bytes: bytes)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public init(from decoder: any Decoder) throws { try self.init(hex: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(hex) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
}

public enum ExtractorSHA256 {
    public static func digest(_ data: Data) -> ExtractorPackageDigest {
        let bytes: [UInt8]
        #if canImport(CryptoKit)
        bytes = Array(SHA256.hash(data: data))
        #elseif canImport(Crypto)
        bytes = Array(SHA256.hash(data: data))
        #else
        #error("ExtractorSHA256 requires CryptoKit or Crypto")
        #endif
        do {
            return try ExtractorPackageDigest(bytes: bytes)
        } catch {
            preconditionFailure("SHA-256 produced an invalid digest: \(error)")
        }
    }
}

/// Exact immutable extractor package revision.
public struct ExtractorPackageRevisionID: Codable, Hashable, Sendable, Comparable {
    public let packageID: ExtractorPackageID
    public let version: ExtractorPackageVersion
    public let digest: ExtractorPackageDigest

    public init(packageID: ExtractorPackageID, version: ExtractorPackageVersion, digest: ExtractorPackageDigest) {
        self.packageID = packageID
        self.version = version
        self.digest = digest
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.packageID != rhs.packageID { return lhs.packageID < rhs.packageID }
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        return lhs.digest < rhs.digest
    }
}

public struct ExtractorRegistrationID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard ExtractorIdentifierRules.isRegistrationID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw ExtractorValidationError.invalidIdentifier(kind: "extractor registration ID", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ExtractorReference: Codable, Hashable, Sendable, Comparable {
    public let revision: ExtractorPackageRevisionID
    public let registrationID: ExtractorRegistrationID

    public init(revision: ExtractorPackageRevisionID, registrationID: ExtractorRegistrationID) {
        self.revision = revision
        self.registrationID = registrationID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision ? lhs.registrationID < rhs.registrationID : lhs.revision < rhs.revision
    }
}

public struct LogicalExtractorReference: Codable, Hashable, Sendable, Comparable {
    public let packageID: ExtractorPackageID
    public let registrationID: ExtractorRegistrationID

    public init(packageID: ExtractorPackageID, registrationID: ExtractorRegistrationID) {
        self.packageID = packageID
        self.registrationID = registrationID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.packageID == rhs.packageID ? lhs.registrationID < rhs.registrationID : lhs.packageID < rhs.packageID
    }
}

public struct ExtractorPackagePluginRunID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
    public init(validating rawValue: String) throws {
        guard let value = UUID(uuidString: rawValue) else { throw ExtractorValidationError.invalidUUID(rawValue) }
        self.init(rawValue: value)
    }
    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue.uuidString.lowercased()) }
}

public struct ExtractorRequestID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
    public init(validating rawValue: String) throws {
        guard let value = UUID(uuidString: rawValue) else { throw ExtractorValidationError.invalidUUID(rawValue) }
        self.init(rawValue: value)
    }
    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue.uuidString.lowercased()) }
}

public struct ExtractorProtocolRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int
    public static let v1 = Self(validatedRawValue: 1)
    public init?(rawValue: Int) { guard rawValue == 1 else { return nil }; self.rawValue = rawValue }
    private init(validatedRawValue: Int) { self.rawValue = validatedRawValue }
    public init(from decoder: any Decoder) throws {
        let rawValue = try Int(from: decoder)
        guard let value = Self(rawValue: rawValue) else { throw ExtractorValidationError.invalidRevision(rawValue) }
        self = value
    }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ExtractorManifestRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int
    public static let v1 = Self(validatedRawValue: 1)
    public init?(rawValue: Int) { guard rawValue == 1 else { return nil }; self.rawValue = rawValue }
    private init(validatedRawValue: Int) { self.rawValue = validatedRawValue }
    public init(from decoder: any Decoder) throws {
        let rawValue = try Int(from: decoder)
        guard let value = Self(rawValue: rawValue) else { throw ExtractorValidationError.invalidRevision(rawValue) }
        self = value
    }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum ExtractorIdentifierRules {
    static func isPackageLabel(_ label: Substring) -> Bool {
        guard let first = label.first, first.isASCII, first.isLetter, first.isLowercase,
              label.count <= 63, label.last != "-" else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    static func isRegistrationID(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter, first.isLowercase,
              value.count <= 64, value.last != "-" else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    static func strictUInt(_ value: Substring) -> UInt? {
        guard value.isEmpty == false, value.allSatisfy(\.isNumber), value.count == 1 || value.first != "0" else { return nil }
        return UInt(value)
    }

    static func isBuildMetadata(_ value: String) -> Bool { isVersionIdentifierList(value) }

    static func isPrerelease(_ value: String) -> Bool {
        isVersionIdentifierList(value) && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            part.allSatisfy(\.isNumber) == false || part.count == 1 || part.first != "0"
        }
    }

    static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let right = rhs.split(separator: ".", omittingEmptySubsequences: false)
        for (leftIdentifier, rightIdentifier) in zip(left, right) {
            let result = comparePrereleaseIdentifier(leftIdentifier, rightIdentifier)
            if result != .orderedSame { return result }
        }
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    private static func isVersionIdentifierList(_ value: String) -> Bool {
        value.isEmpty == false && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            part.isEmpty == false && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func comparePrereleaseIdentifier(_ lhs: Substring, _ rhs: Substring) -> ComparisonResult {
        let leftIsNumeric = lhs.allSatisfy(\.isNumber)
        let rightIsNumeric = rhs.allSatisfy(\.isNumber)
        switch (leftIsNumeric, rightIsNumeric) {
        case (true, true):
            if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (true, false): return .orderedAscending
        case (false, true): return .orderedDescending
        case (false, false): return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
    }
}

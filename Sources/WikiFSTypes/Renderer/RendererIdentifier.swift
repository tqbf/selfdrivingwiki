import Foundation

// pattern: Functional Core

/// Stable identity of one installed renderer package. The canonical form is a
/// lowercase reverse-DNS name with at least two labels.
public struct RendererPackageID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard RendererIdentifierRules.isPackageID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw RendererValidationError.invalidIdentifier(kind: "renderer package ID", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Immutable semantic version of a renderer package.
public struct RendererPackageVersion: RawRepresentable, Codable, Hashable, Sendable, Comparable {
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
              let major = RendererIdentifierRules.strictUInt(numbers[0]),
              let minor = RendererIdentifierRules.strictUInt(numbers[1]),
              let patch = RendererIdentifierRules.strictUInt(numbers[2]),
              components.count <= 2,
              (components.count == 1 || RendererIdentifierRules.isBuildMetadata(String(components[1]))),
              (versionAndPrerelease.count == 1 || RendererIdentifierRules.isPrerelease(String(versionAndPrerelease[1])))
        else { return nil }
        self.rawValue = rawValue
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = versionAndPrerelease.count == 2 ? String(versionAndPrerelease[1]) : nil
        self.buildMetadata = components.count == 2 ? String(components[1]) : nil
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else { throw RendererValidationError.invalidVersion(rawValue) }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return lhs.rawValue < rhs.rawValue
        case (nil, .some): return false
        case (.some, nil): return true
        case let (.some(left), .some(right)):
            let precedence = RendererIdentifierRules.comparePrerelease(left, right)
            if precedence != .orderedSame { return precedence == .orderedAscending }
            return lhs.rawValue < rhs.rawValue
        }
    }
}

/// Identity of one renderer registration within a package version.
public struct RendererRegistrationID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard RendererIdentifierRules.isRegistrationID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw RendererValidationError.invalidIdentifier(kind: "renderer registration ID", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Closed host-owned identity for a native renderer.
public struct BuiltInRendererID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard RendererIdentifierRules.isRegistrationID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw RendererValidationError.invalidIdentifier(kind: "built-in renderer ID", value: rawValue)
        }
        self = value
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Pin to one immutable renderer registration.
public struct RendererReference: Codable, Hashable, Sendable, Comparable {
    public let packageID: RendererPackageID
    public let version: RendererPackageVersion
    public let registrationID: RendererRegistrationID

    public init(packageID: RendererPackageID, version: RendererPackageVersion, registrationID: RendererRegistrationID) {
        self.packageID = packageID
        self.version = version
        self.registrationID = registrationID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.packageID, lhs.version, lhs.registrationID) < (rhs.packageID, rhs.version, rhs.registrationID)
    }
}

/// A preference that can resolve to a compatible package version.
public struct LogicalRendererReference: Codable, Hashable, Sendable, Comparable {
    public let packageID: RendererPackageID
    public let registrationID: RendererRegistrationID

    public init(packageID: RendererPackageID, registrationID: RendererRegistrationID) {
        self.packageID = packageID
        self.registrationID = registrationID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.packageID, lhs.registrationID) < (rhs.packageID, rhs.registrationID)
    }
}

/// The identifier validation used by every public string boundary in this module.
enum RendererIdentifierRules {
    static func isPackageID(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy(isPackageLabel)
    }

    static func isPackageLabel(_ label: Substring) -> Bool {
        guard let first = label.first, first.isASCII, first.isLetter, first.isLowercase,
              label.count <= 63 else { return false }
        return label.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "-")
        } && label.last != "-"
    }

    static func isRegistrationID(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter, first.isLowercase,
              value.count <= 64, value.last != "-" else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "-")
        }
    }

    static func strictUInt(_ value: Substring) -> UInt? {
        guard value.isEmpty == false, value.allSatisfy(\.isNumber), value.count == 1 || value.first != "0" else {
            return nil
        }
        return UInt(value)
    }

    static func isBuildMetadata(_ value: String) -> Bool {
        isVersionIdentifierList(value)
    }

    static func isPrerelease(_ value: String) -> Bool {
        isVersionIdentifierList(value) && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            part.allSatisfy(\.isNumber) == false || part.count == 1 || part.first != "0"
        }
    }

    static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let right = rhs.split(separator: ".", omittingEmptySubsequences: false)
        for (leftIdentifier, rightIdentifier) in zip(left, right) {
            let identifierComparison = comparePrereleaseIdentifier(leftIdentifier, rightIdentifier)
            if identifierComparison != .orderedSame { return identifierComparison }
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

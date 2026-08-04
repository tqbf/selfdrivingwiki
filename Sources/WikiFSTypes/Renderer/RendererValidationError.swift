import Foundation

// pattern: Functional Core

/// Rejection reason at a renderer contract boundary.
public enum RendererValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidIdentifier(kind: String, value: String)
    case invalidVersion(String)
    case invalidRelativePath(String)
    case invalidMIMEType(String)
    case invalidExtension(String)
    case invalidSignature
    case invalidSizeLimit(String)
    case invalidCompatibilityRange
    case invalidPresentation
    case forbiddenCapability(RendererCapability)
    case missingRequiredCapability(RendererCapability)
    case duplicateRegistration(RendererRegistrationID)
    case duplicatePath(RendererRelativePath)
    case duplicateAsset(RendererRelativePath)
    case unsupportedManifestRevision(Int)
    case manifestIdentityMismatch
    case manifestAssetNotApproved(RendererRelativePath)
    case emptyManifest
    case packageManifestContainsBuiltIn(BuiltInRendererID)
    case builtInRegistryContainsInstalled(RendererRegistrationID)
    case installedRegistryContainsBuiltIn(RendererRegistrationID)
    case emptyPreference
    case mismatchedPreferenceIdentity

    public var description: String {
        switch self {
        case let .invalidIdentifier(kind, value): "invalid \(kind): \(value)"
        case let .invalidVersion(value): "invalid renderer package version: \(value)"
        case let .invalidRelativePath(value): "invalid renderer relative path: \(value)"
        case let .invalidMIMEType(value): "invalid MIME type: \(value)"
        case let .invalidExtension(value): "invalid extension: \(value)"
        case .invalidSignature: "invalid bounded signature"
        case let .invalidSizeLimit(value): "invalid renderer size limit: \(value)"
        case .invalidCompatibilityRange: "invalid compatibility revision range"
        case .invalidPresentation: "invalid renderer presentation for implementation"
        case let .forbiddenCapability(capability): "forbidden renderer capability: \(capability.rawValue)"
        case let .missingRequiredCapability(capability): "missing required renderer capability: \(capability.rawValue)"
        case let .duplicateRegistration(id): "duplicate renderer registration: \(id.rawValue)"
        case let .duplicatePath(path): "duplicate renderer path: \(path.rawValue)"
        case let .duplicateAsset(path): "duplicate renderer asset: \(path.rawValue)"
        case let .unsupportedManifestRevision(revision): "unsupported renderer manifest revision: \(revision)"
        case .manifestIdentityMismatch: "renderer descriptor does not match manifest identity"
        case let .manifestAssetNotApproved(path): "renderer descriptor does not approve manifest asset: \(path.rawValue)"
        case .emptyManifest: "renderer manifest must register at least one renderer"
        case let .packageManifestContainsBuiltIn(id): "renderer package manifest cannot contain built-in renderer: \(id.rawValue)"
        case let .builtInRegistryContainsInstalled(id): "built-in renderer registry input contains installed renderer: \(id.rawValue)"
        case let .installedRegistryContainsBuiltIn(id): "installed renderer registry input contains built-in renderer: \(id.rawValue)"
        case .emptyPreference: "renderer preference has no exact or logical reference"
        case .mismatchedPreferenceIdentity: "renderer preference exact and logical identities differ"
        }
    }
}

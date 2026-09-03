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
    case invalidJSONMatcher
    case invalidSizeLimit(String)
    case invalidCompatibilityRange
    case invalidPresentation
    case missingEmbeddingRoles
    case invalidFenceAlias(String)
    case fenceClaimMissingDisclosureRole(RendererFenceAlias)
    case duplicateFenceClaim(RendererFenceAlias)
    case fenceClaimsRequireCurrentRevision
    case fenceValidationRequiresCurrentRevision
    case fenceValidationAssetNotApproved(RendererRelativePath)
    case fenceValidationAssetsNotDistinct
    case fenceValidationEntryFunctionInvalid
    case reservedFenceAlias(RendererFenceAlias)
    case conflictingFenceAlias(RendererFenceAlias)
    case forbiddenCapability(RendererCapability)
    case missingRequiredCapability(RendererCapability)
    case emptyHostNavigationDeclaration
    case hostNavigationCapabilityRequiresDeclaration
    case hostNavigationDeclarationRequiresCapability
    case hostNavigationRequiresWebPackage
    case hostNavigationRequiresRevision4
    case emptyAssetReadDeclaration
    case unsupportedAssetMIMEType
    case invalidAssetReadLimit(String)
    case assetReadCapabilityRequiresDeclaration
    case assetReadDeclarationRequiresCapability
    case assetReadRequiresWebPackage
    case assetReadRequiresRevision5
    case extractorAssetNotApproved(RendererRelativePath)
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
        case .invalidJSONMatcher: "invalid bounded JSON matcher"
        case let .invalidSizeLimit(value): "invalid renderer size limit: \(value)"
        case .invalidCompatibilityRange: "invalid compatibility revision range"
        case .invalidPresentation: "invalid renderer presentation for implementation"
        case .missingEmbeddingRoles: "renderer must declare at least one supported embedding role"
        case let .invalidFenceAlias(value): "invalid renderer fence alias: \(value)"
        case let .fenceClaimMissingDisclosureRole(alias): "fence claim requires the disclosureRow embedding role: \(alias.rawValue)"
        case let .duplicateFenceClaim(alias): "duplicate renderer fence claim: \(alias.rawValue)"
        case .fenceClaimsRequireCurrentRevision: "renderer fence claims require manifest revision 2"
        case .fenceValidationRequiresCurrentRevision: "renderer fence validation declarations require manifest revision 3"
        case let .fenceValidationAssetNotApproved(path): "renderer fence validation asset is not approved by the declaring descriptor: \(path.rawValue)"
        case .fenceValidationAssetsNotDistinct: "renderer fence validation engine and wrapper assets must be distinct paths"
        case .fenceValidationEntryFunctionInvalid: "renderer fence validation entry function must be a JavaScript identifier"
        case let .reservedFenceAlias(alias): "renderer fence alias is reserved by a built-in renderer: \(alias.rawValue)"
        case let .conflictingFenceAlias(alias): "renderer fence alias is already claimed by an installed package: \(alias.rawValue)"
        case let .forbiddenCapability(capability): "forbidden renderer capability: \(capability.rawValue)"
        case let .missingRequiredCapability(capability): "missing required renderer capability: \(capability.rawValue)"
        case .emptyHostNavigationDeclaration: "renderer host navigation must declare at least one target kind"
        case .hostNavigationCapabilityRequiresDeclaration: "renderer hostNavigation capability requires a navigation declaration"
        case .hostNavigationDeclarationRequiresCapability: "renderer navigation declaration requires the hostNavigation capability"
        case .hostNavigationRequiresWebPackage: "renderer host navigation is available only to Web packages"
        case .hostNavigationRequiresRevision4: "renderer host navigation requires manifest revision 4"
        case .emptyAssetReadDeclaration: "renderer asset read must declare at least one role and one approved MIME type"
        case .unsupportedAssetMIMEType: "renderer asset read declares an unsupported asset MIME type"
        case let .invalidAssetReadLimit(value): "invalid renderer asset read limit: \(value)"
        case .assetReadCapabilityRequiresDeclaration: "renderer assetRead capability requires an asset read declaration"
        case .assetReadDeclarationRequiresCapability: "renderer asset read declaration requires the assetRead capability"
        case .assetReadRequiresWebPackage: "renderer asset read is available only to Web packages"
        case .assetReadRequiresRevision5: "renderer asset read requires manifest revision 5"
        case let .extractorAssetNotApproved(path): "renderer reference-extractor asset is not approved by the declaring descriptor: \(path.rawValue)"
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

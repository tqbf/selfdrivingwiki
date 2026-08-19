import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// pattern: Mixed (unavoidable)
// Reason: this is the narrow package-filesystem boundary. Its policy decisions
// are value based, while its no-follow reads and identity checks are I/O.

/// Stable URL syntax for resources served from an installed renderer package.
/// These URLs name a package asset; they never contain the package's file URL.
public enum RendererPackageScheme {
    public static let name = "renderer-package"
    private static let authority = "package"

    public static func url(
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        path: RendererRelativePath
    ) -> URL {
        var components = URLComponents()
        components.scheme = name
        components.host = authority
        components.path = "/\(packageID.rawValue)/\(version.rawValue)/\(path.rawValue)"
        guard let url = components.url else {
            preconditionFailure("Failed to construct a renderer package URL")
        }
        return url
    }

    public static func request(from url: URL) throws -> Request {
        guard url.scheme == name,
              url.host == authority,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil
        else { throw RendererPackageResourceError.invalidRequest }

        guard let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RendererPackageResourceError.invalidRequest
        }
        let components = urlComponents.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3,
              let packageID = RendererPackageID(rawValue: String(components[0])),
              let version = RendererPackageVersion(rawValue: String(components[1]))
        else { throw RendererPackageResourceError.invalidRequest }

        let rawPath = components.dropFirst(2).joined(separator: "/")
        guard let path = RendererRelativePath(rawValue: rawPath)
        else { throw RendererPackageResourceError.invalidRequest }
        return Request(packageID: packageID, version: version, path: path)
    }

    public struct Request: Hashable, Sendable {
        public let packageID: RendererPackageID
        public let version: RendererPackageVersion
        public let path: RendererRelativePath
    }
}

public enum RendererPackageResourceError: Error, Equatable, Sendable {
    case invalidRequest
    case packageIdentityMismatch
    case packageRevalidationFailed
    case undeclaredAsset
    case unsupportedMIMEType
    case filesystemChanged
    case assetHashMismatch
}

public struct RendererPackageResource: Sendable {
    public let data: Data
    public let mimeType: RendererMIMEType
    public let isEntryDocument: Bool

    public init(data: Data, mimeType: RendererMIMEType, isEntryDocument: Bool) {
        self.data = data
        self.mimeType = mimeType
        self.isEntryDocument = isEntryDocument
    }
}

/// The only resource lookup surface exposed to a package scheme handler.
/// Implementations return bytes, never a local file URL.
public protocol RendererPackageResourceProviding: Sendable {
    func resource(for url: URL) throws -> RendererPackageResource
}

/// Serves one validated, version-pinned package directory. The package is
/// validated before the provider is created; each response still reopens the
/// requested manifest asset without following links and rechecks its identity
/// and digest.
public struct ValidatedRendererPackageResourceProvider: RendererPackageResourceProviding {
    public let packageID: RendererPackageID
    public let version: RendererPackageVersion
    public let expectedPackageHash: RendererSHA256Digest
    public let installedRoot: URL

    private let validatedPackage: ValidatedRendererPackage
    private let fileSystem: any RendererPackageFileSystem
    private let diagnose: @Sendable (String) -> Void

    public init(
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        expectedPackageHash: RendererSHA256Digest,
        installedRoot: URL,
        validator: RendererPackageValidator,
        fileSystem: any RendererPackageFileSystem = RealRendererPackageFileSystem(),
        diagnose: @escaping @Sendable (String) -> Void = { DebugLog.store($0) }
    ) throws {
        let installedRoot = installedRoot.standardizedFileURL
        let validatedPackage = try validator.revalidateDirectory(installedRoot, expectedHash: expectedPackageHash)
        try self.init(
            packageID: packageID,
            version: version,
            expectedPackageHash: expectedPackageHash,
            installedRoot: installedRoot,
            validatedPackage: validatedPackage,
            fileSystem: fileSystem,
            diagnose: diagnose
        )
    }

    /// Creates a provider from a package that was validated before the WebKit
    /// session was created. Requests still perform per-asset no-follow,
    /// identity, size, and digest checks, but do not rehash the whole package.
    public init(
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        expectedPackageHash: RendererSHA256Digest,
        installedRoot: URL,
        validatedPackage: ValidatedRendererPackage,
        fileSystem: any RendererPackageFileSystem = RealRendererPackageFileSystem(),
        diagnose: @escaping @Sendable (String) -> Void = { DebugLog.store($0) }
    ) throws {
        let installedRoot = installedRoot.standardizedFileURL
        guard validatedPackage.stagedRoot.standardizedFileURL == installedRoot,
              validatedPackage.packageHash == expectedPackageHash,
              validatedPackage.manifest.packageID == packageID,
              validatedPackage.manifest.version == version
        else { throw RendererPackageResourceError.packageRevalidationFailed }
        self.packageID = packageID
        self.version = version
        self.expectedPackageHash = expectedPackageHash
        self.installedRoot = installedRoot
        self.validatedPackage = validatedPackage
        self.fileSystem = fileSystem
        self.diagnose = diagnose
    }

    public func resource(for url: URL) throws -> RendererPackageResource {
        let request = try RendererPackageScheme.request(from: url)
        guard request.packageID == packageID, request.version == version else {
            return try fail(.packageIdentityMismatch)
        }

        let package = validatedPackage
        guard package.manifest.packageID == packageID,
              package.manifest.version == version,
              package.packageHash == expectedPackageHash
        else { return try fail(.packageIdentityMismatch) }

        guard let asset = package.manifest.assets.first(where: { $0.path == request.path }) else {
            return try fail(.undeclaredAsset)
        }
        guard let mimeType = RendererPackageMIMEType.mimeType(for: request.path) else {
            return try fail(.unsupportedMIMEType)
        }

        let assetURL = installedRoot.appendingPathComponent(request.path.rawValue, isDirectory: false)
        guard isRendererPackageStorePathContained(assetURL, within: installedRoot) else {
            return try fail(.invalidRequest)
        }
        let before: RendererPackageFileIdentity
        do {
            before = try fileSystem.lstat(at: assetURL)
            guard isRegularFile(before), before.linkCount == 1 else { return try fail(.filesystemChanged) }
            let descriptor = try fileSystem.openReadOnlyNoFollow(at: assetURL)
            defer {
                do { try fileSystem.close(fileDescriptor: descriptor) }
                catch { diagnose("Renderer package resource descriptor close failed.") }
            }
            let opened = try fileSystem.fileIdentity(fileDescriptor: descriptor)
            guard before.refersToSameObject(as: opened), opened.linkCount == 1, isRegularFile(opened) else {
                return try fail(.filesystemChanged)
            }
            let data = try fileSystem.readAll(fileDescriptor: descriptor, maximumBytes: RendererPackageValidationLimits.maximumCopiedByteCount)
            let after = try fileSystem.fileIdentity(fileDescriptor: descriptor)
            guard opened == after else { return try fail(.filesystemChanged) }
            guard RendererSHA256.digest(data) == asset.digest else { return try fail(.assetHashMismatch) }
            return RendererPackageResource(
                data: data,
                mimeType: mimeType,
                isEntryDocument: package.manifest.descriptors.contains { descriptor in
                    if case let .webPackage(entryPoint) = descriptor.implementation {
                        return entryPoint.path == request.path
                    }
                    return false
                }
            )
        } catch let error as RendererPackageResourceError {
            throw error
        } catch {
            return try fail(.filesystemChanged)
        }
    }

    private func fail<T>(_ error: RendererPackageResourceError) throws -> T {
        diagnose("Renderer package resource request denied: \(redactedReason(error)).")
        throw error
    }

    private func redactedReason(_ error: RendererPackageResourceError) -> String {
        switch error {
        case .invalidRequest: return "invalid request"
        case .packageIdentityMismatch: return "package identity mismatch"
        case .packageRevalidationFailed: return "package revalidation failed"
        case .undeclaredAsset: return "undeclared asset"
        case .unsupportedMIMEType: return "unsupported MIME type"
        case .filesystemChanged: return "filesystem identity changed"
        case .assetHashMismatch: return "asset hash mismatch"
        }
    }

    private func isRegularFile(_ identity: RendererPackageFileIdentity) -> Bool {
        (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFREG)
    }
}

// pattern: Functional Core

public enum RendererPackageMIMEType {
    private static let types: [String: RendererMIMEType] = [
        "css": type("text/css"),
        "gif": type("image/gif"),
        "html": type("text/html"),
        "jpeg": type("image/jpeg"),
        "jpg": type("image/jpeg"),
        "js": type("text/javascript"),
        "json": type("application/json"),
        "mjs": type("text/javascript"),
        "png": type("image/png"),
        "svg": type("image/svg+xml"),
        "wasm": type("application/wasm"),
        "webp": type("image/webp"),
        "woff": type("font/woff"),
        "woff2": type("font/woff2"),
    ]

    public static func mimeType(for path: RendererRelativePath) -> RendererMIMEType? {
        let extensionValue = path.rawValue.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init)?.lowercased()
        guard let extensionValue else { return nil }
        return types[extensionValue]
    }

    private static func type(_ rawValue: String) -> RendererMIMEType {
        guard let type = RendererMIMEType(rawValue: rawValue) else {
            preconditionFailure("Invalid built-in renderer MIME type")
        }
        return type
    }
}

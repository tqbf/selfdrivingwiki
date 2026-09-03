#if os(macOS)
import Foundation
import WikiFSCore

// pattern: Functional Core (typed URL/token) + Imperative Shell (route table)

/// Cryptographically random, capability-strength security-origin host for one
/// admitted package iframe. The token is the iframe's origin host in
/// `renderer-package://<token>/<package>/<version>/<path>` URLs. It is never
/// derived from a package name, path, or any package-authored value, so one
/// frame's origin cannot be guessed or replayed by another.
struct RendererFrameOriginToken: Hashable, Equatable, Sendable {
    let rawValue: String

    private static let byteCount = 16

    /// 128 bits of randomness from the system CSPRNG, lowercase hex. Lowercase
    /// because WebKit normalizes URL hosts to lowercase; a mixed-case token
    /// would not compare equal to the reported `WKSecurityOrigin.host`.
    static func generate() -> Self {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // The CSPRNG failing is unrecoverable for a capability token;
            // fail closed rather than minting a guessable origin.
            preconditionFailure("SecRandomCopyBytes failed: \(status)")
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return Self(rawValue: hex)
    }
}

/// Typed parse of a frame-scoped package URL:
/// `renderer-package://<frame-token>/<package-id>/<version>/<path>`.
///
/// The frame token occupies the URL host, so every relative asset the package
/// entry document loads resolves against the same unguessable origin host.
/// Parsing rejects userinfo, ports, queries, and fragments exactly like the
/// canonical `RendererPackageScheme.request(from:)`.
struct RendererFramePackageURL: Hashable, Equatable, Sendable {
    let token: RendererFrameOriginToken
    let request: RendererPackageScheme.Request

    static func parse(_ url: URL) throws -> Self {
        guard url.scheme == RendererPackageScheme.name,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil
        else { throw RendererPackageResourceError.invalidRequest }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RendererPackageResourceError.invalidRequest
        }
        // The token is the host; base64url alphabet only.
        let rawToken = components.host ?? ""
        guard !rawToken.isEmpty,
              rawToken.unicodeScalars.allSatisfy(Self.isTokenScalarLegal)
        else { throw RendererPackageResourceError.invalidRequest }
        let pathComponents = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count >= 3,
              let packageID = RendererPackageID(rawValue: String(pathComponents[0])),
              let version = RendererPackageVersion(rawValue: String(pathComponents[1]))
        else { throw RendererPackageResourceError.invalidRequest }
        let rawPath = pathComponents.dropFirst(2).joined(separator: "/")
        guard let path = RendererRelativePath(rawValue: rawPath) else {
            throw RendererPackageResourceError.invalidRequest
        }
        // `RendererPackageScheme.Request`'s memberwise init is internal to
        // WikiFSCore, so reconstruct the request by parsing the canonical
        // URL form (which also revalidates the path).
        let canonical = RendererPackageScheme.url(
            packageID: packageID,
            version: version,
            path: path)
        return Self(
            token: RendererFrameOriginToken(rawValue: rawToken),
            request: try RendererPackageScheme.request(from: canonical))
    }

    /// The iframe's `src` for the package entry (or an admitted asset).
    static func frameURL(
        token: RendererFrameOriginToken,
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        path: RendererRelativePath
    ) -> URL {
        var components = URLComponents()
        components.scheme = RendererPackageScheme.name
        components.host = token.rawValue
        components.path = "/\(packageID.rawValue)/\(version.rawValue)/\(path.rawValue)"
        guard let url = components.url else {
            preconditionFailure("Failed to construct a frame-scoped package URL")
        }
        return url
    }

    /// Rewrites the frame-scoped URL to the canonical package form the
    /// validated underlying provider understands:
    /// `renderer-package://package/<package>/<version>/<path>`.
    var canonicalURL: URL {
        RendererPackageScheme.url(
            packageID: request.packageID,
            version: request.version,
            path: request.path)
    }

    private static func isTokenScalarLegal(_ scalar: Unicode.Scalar) -> Bool {
        ("0" ... "9").contains(Character(scalar)) || scalar == "-"
    }
}

/// One admitted frame route: an unguessable origin host mapped to exactly one
/// package reservation and its validated resource provider.
private struct ReaderFrameRoute: Sendable {
    let reservation: RendererPackageReservation
    let provider: any RendererPackageResourceProviding
}

/// The reader's package routing provider, consumed by the canonical
/// `RendererPackageSchemeHandler` registered on `WikiReaderWebView`. It maps
/// one frame-origin token to one admitted package reservation and rewrites
/// requests to the canonical package URL before delegating to the validated
/// underlying provider. CSP, MIME, no-sniff, response ordering, and task
/// cancellation remain single-sourced in the canonical handler.
///
/// A request whose token was never admitted — or whose package/version does
/// not match the token's route — fails closed, so an in-page expansion iframe
/// can only load packages the host validated for that exact frame.
///
/// WebKit calls the scheme handler on its own queue while the main actor may
/// admit or revoke routes, so the route table is guarded by a lock. The lock
/// is held only to copy the selected route out; package file I/O happens
/// after release (`resource(for:)` never holds it).
// swiftlint:disable:next unchecked_sendable
final class ReaderRendererPackageRouter: RendererPackageResourceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [RendererFrameOriginToken: ReaderFrameRoute] = [:]

    /// Diagnostic record of every URL handed to `resource(for:)`. Read only
    /// from tests; production code never touches it.
    private(set) var diagnosticStartedRequests: [URL] = []

    init() {}

    /// Admits one frame route and returns the frame-scoped entry URL to use
    /// as the iframe's `src`.
    func admit(
        token: RendererFrameOriginToken,
        reservation: RendererPackageReservation,
        entryPath: RendererRelativePath,
        provider: any RendererPackageResourceProviding
    ) -> URL {
        lock.lock()
        defer { lock.unlock() }
        routes[token] = ReaderFrameRoute(reservation: reservation, provider: provider)
        return RendererFramePackageURL.frameURL(
            token: token,
            packageID: reservation.packageID,
            version: reservation.version,
            path: entryPath)
    }

    /// Revokes one frame's route. Later requests for that origin fail closed.
    func revoke(token: RendererFrameOriginToken) {
        lock.lock()
        defer { lock.unlock() }
        routes.removeValue(forKey: token)
    }

    /// Revokes every route (document replacement, snapshot replacement,
    /// reader dismantle). Active frames' requests then fail closed.
    func revokeAll() {
        lock.lock()
        defer { lock.unlock() }
        routes.removeAll()
    }

    var activeRouteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return routes.count
    }

    /// The canonical provider lookup. Copies the route under lock, releases,
    /// verifies the request matches the admitted reservation, then delegates
    /// to the validated provider with the canonical URL.
    func resource(for url: URL) throws -> RendererPackageResource {
        let frameURL = try RendererFramePackageURL.parse(url)
        lock.lock()
        diagnosticStartedRequests.append(url)
        guard let admitted = routes[frameURL.token] else {
            lock.unlock()
            throw RendererPackageResourceError.packageIdentityMismatch
        }
        // One origin host serves exactly one package reservation.
        guard admitted.reservation.packageID == frameURL.request.packageID,
              admitted.reservation.version == frameURL.request.version
        else {
            lock.unlock()
            throw RendererPackageResourceError.packageIdentityMismatch
        }
        // Validated package file I/O runs outside the critical section.
        let provider = admitted.provider
        lock.unlock()
        return try provider.resource(for: frameURL.canonicalURL)
    }
}
#endif

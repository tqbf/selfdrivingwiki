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
    /// A token is exactly 128 bits of randomness rendered as lowercase hex.
    private static let characterCount = 32

    /// The exact token shape `generate()` emits: 32 lowercase hex characters.
    /// Sharing this parser with `RendererFramePackageURL.parse` keeps the
    /// token invariant in one implementation.
    private static func isValidShape(_ rawValue: String) -> Bool {
        rawValue.count == characterCount &&
            rawValue.unicodeScalars.allSatisfy { scalar in
                ("0" ... "9").contains(Character(scalar))
                    || ("a" ... "f").contains(Character(scalar))
            }
    }

    /// Returns the token only if the raw value matches the generate() shape
    /// (exactly 32 lowercase hex characters). Prevents arbitrary host strings
    /// from becoming tokens.
    static func tokenIfValid(_ rawValue: String) -> RendererFrameOriginToken? {
        isValidShape(rawValue) ? Self(rawValue: rawValue) : nil
    }

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
        // The token is the host; it must match the exact generate() shape
        // (one shared invariant implementation with tokenIfValid).
        let rawToken = components.host ?? ""
        guard let token = RendererFrameOriginToken.tokenIfValid(rawToken) else {
            throw RendererPackageResourceError.invalidRequest
        }
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
            token: token,
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

    /// Serves the frame-scoped input bootstrap for one token, consumed when
    /// the entry document is served. Set by the reader at admission.
    private let bootstrapLookup: @Sendable (RendererFrameOriginToken) -> String?

    /// Diagnostic record of every URL handed to `resource(for:)`. Read only
    /// from tests; production code never touches it.
    private(set) var diagnosticStartedRequests: [URL] = []

    init(bootstrapLookup: @escaping @Sendable (RendererFrameOriginToken) -> String? = { _ in nil }) {
        self.bootstrapLookup = bootstrapLookup
    }

    /// Frame-scoped input bootstrap **JS** per admitted token. Served as a
    /// separate `renderer-input.js` script file (the package CSP blocks
    /// inline scripts, and WKUserScripts added post-load don't run in
    /// subframes).
    private var inputBootstraps: [RendererFrameOriginToken: String] = [:]

    /// Attaches the frame-scoped input bootstrap to one admitted route. The
    /// router serves it as `renderer-input.js` and inlines a `<script src>`
    /// reference into the entry document before the package's own scripts.
    func setFrameBootstrap(token: RendererFrameOriginToken, html: String) {
        lock.lock()
        defer { lock.unlock() }
        inputBootstraps[token] = html
    }

    /// Returns the validated provider for a reference — the admitted route
    /// matching the reference's exact package, version, and registration.
    func provider(for reference: RendererReference) -> (any RendererPackageResourceProviding)? {
        lock.lock()
        defer { lock.unlock() }
        return routes.values.first {
            $0.reservation.packageID == reference.packageID
                && $0.reservation.version == reference.version
        }?.provider
    }

    /// Revokes one frame's route and its bootstrap. Later requests for that
    /// origin fail closed.
    func revoke(token: RendererFrameOriginToken) {
        lock.lock()
        defer { lock.unlock() }
        routes.removeValue(forKey: token)
        inputBootstraps.removeValue(forKey: token)
    }

    /// Admits one frame route and returns the frame-scoped entry URL to use
    /// as the iframe's `src`.
    func admit(
        token: RendererFrameOriginToken,
        reservation: RendererPackageReservation,
        entryPath: RendererRelativePath,
        provider: any RendererPackageResourceProviding,
        inputBootstrapHTML: String? = nil
    ) -> URL {
        lock.lock()
        defer { lock.unlock() }
        routes[token] = ReaderFrameRoute(reservation: reservation, provider: provider)
        if let inputBootstrapHTML {
            inputBootstraps[token] = inputBootstrapHTML
        }
        return RendererFramePackageURL.frameURL(
            token: token,
            packageID: reservation.packageID,
            version: reservation.version,
            path: entryPath)
    }

    /// Revokes every route (document replacement, snapshot replacement,
    /// reader dismantle). Active frames' requests then fail closed.
    func revokeAll() {
        lock.lock()
        defer { lock.unlock() }
        routes.removeAll()
        inputBootstraps.removeAll()
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
            DebugLog.reader("package-router: unknown frame token \(frameURL.token.rawValue) for \(frameURL.request.packageID.rawValue)/\(frameURL.request.version.rawValue)/\(frameURL.request.path.rawValue)")
            throw RendererPackageResourceError.packageIdentityMismatch
        }
        // One origin host serves exactly one package reservation.
        guard admitted.reservation.packageID == frameURL.request.packageID,
              admitted.reservation.version == frameURL.request.version
        else {
            lock.unlock()
            DebugLog.reader("package-router: reservation mismatch for \(frameURL.request.packageID.rawValue)/\(frameURL.request.version.rawValue)")
            throw RendererPackageResourceError.packageIdentityMismatch
        }
        // Validated package file I/O runs outside the critical section.
        let provider = admitted.provider
        lock.unlock()
        DebugLog.reader("package-router: serving \(frameURL.request.packageID.rawValue)/\(frameURL.request.version.rawValue)/\(frameURL.request.path.rawValue) for frame \(frameURL.token.rawValue)")

        // Serve the frame-scoped input bootstrap as its own script file. The
        // package CSP allows external renderer-package: scripts but blocks
        // inline ones, and WKUserScripts added post-load don't run in
        // subframes — so the bootstrap must be a real served file.
        if frameURL.request.path.rawValue == "renderer-input.js" {
            lock.lock()
            let bootstrapJS = inputBootstraps[frameURL.token]
            lock.unlock()
            if let bootstrapJS,
               let mime = RendererMIMEType(rawValue: "text/javascript") {
                DebugLog.reader("package-router: serving renderer-input.js for frame \(frameURL.token.rawValue)")
                return RendererPackageResource(
                    data: Data(bootstrapJS.utf8),
                    mimeType: mime,
                    isEntryDocument: false)
            }
        }

        let resource = try provider.resource(for: frameURL.canonicalURL)

        // Entry document: inline a <script src="renderer-input.js"> reference
        // BEFORE the package's own script tags, so the input selector exists
        // when viewer.js runs. The bootstrap itself is served separately.
        if resource.isEntryDocument,
           let html = String(data: resource.data, encoding: .utf8),
           html.utf8.count <= RendererPackageValidationLimits.maximumCopiedByteCount {
            lock.lock()
            let hasBootstrap = inputBootstraps[frameURL.token] != nil
            lock.unlock()
            guard hasBootstrap else {
                DebugLog.reader("package-router: no input bootstrap for frame \(frameURL.token.rawValue)")
                return resource
            }
            let reference = "<script src=\"renderer-input.js\"></script>"
            var patched = html
            if let firstScriptRange = patched.lowercased().range(of: "<script") {
                patched.insert(contentsOf: reference, at: firstScriptRange.lowerBound)
            } else if let bodyEnd = patched.lowercased().range(of: "</body>") {
                patched.insert(contentsOf: reference, at: bodyEnd.lowerBound)
            } else {
                DebugLog.reader("package-router: entry document has no script or body tag; bootstrap reference not inlined")
                return resource
            }
            DebugLog.reader("package-router: inlined renderer-input.js reference into entry document for frame \(frameURL.token.rawValue)")
            return RendererPackageResource(
                data: Data(patched.utf8),
                mimeType: resource.mimeType,
                isEntryDocument: resource.isEntryDocument)
        }
        return resource
    }
}
#endif

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

/// A host-composed frame resource: trusted host overlay bytes served under a
/// frame's origin. These bytes are never package assets — they carry no
/// manifest digest — and the reserved `__host__/` namespace guarantees a
/// package cannot shadow or collide with them.
struct RendererFrameResource: Sendable {
    enum Source: Sendable, Equatable {
        /// Host-composed overlay bytes (e.g. the input bootstrap script).
        case trustedHostOverlay
    }

    let data: Data
    let mimeType: RendererMIMEType
    let source: Source
}

/// The host-side composition layer for frame resources. It serves only typed
/// `RendererFrameResource` overlays under the reserved `__host__/` namespace;
/// every other request falls through to the validated package provider.
@MainActor
final class ReaderFrameResourceComposer {
    private var overlays: [RendererFrameOriginToken: [String: RendererFrameResource]] = [:]

    /// Attaches the frame-scoped input bootstrap overlay for one token.
    func setInputBootstrap(token: RendererFrameOriginToken, javaScript: String) {
        guard let mime = RendererMIMEType(rawValue: "text/javascript") else { return }
        overlays[token, default: [:]][RendererFrameHostNamespace.inputBootstrapPath] =
            RendererFrameResource(
                data: Data(javaScript.utf8),
                mimeType: mime,
                source: .trustedHostOverlay)
    }

    /// Drops every overlay for one token (scoped close).
    func revoke(token: RendererFrameOriginToken) {
        overlays.removeValue(forKey: token)
    }

    /// Drops every overlay (document replacement, dismantle).
    func revokeAll() {
        overlays.removeAll()
    }

    func overlay(token: RendererFrameOriginToken, path: String) -> RendererFrameResource? {
        overlays[token]?[path]
    }
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

    /// The host-composed frame resource layer. Frame overlays (input
    /// bootstrap) live here, never in the route table; the overlay map is
    /// guarded by the router's own lock, which the composer borrows through
    /// the router's synchronized accessors.
    // swiftlint:disable:next unchecked_sendable
    private final class Composer: @unchecked Sendable {
        private let lock: NSLock
        private var overlays: [RendererFrameOriginToken: [String: RendererFrameResource]] = [:]

        init(lock: NSLock) {
            self.lock = lock
        }

        func setInputBootstrap(token: RendererFrameOriginToken, javaScript: String) {
            guard let mime = RendererMIMEType(rawValue: "text/javascript") else { return }
            lock.lock()
            defer { lock.unlock() }
            overlays[token, default: [:]][RendererFrameHostNamespace.inputBootstrapPath] =
                RendererFrameResource(
                    data: Data(javaScript.utf8),
                    mimeType: mime,
                    source: .trustedHostOverlay)
        }

        func revoke(token: RendererFrameOriginToken) {
            lock.lock()
            defer { lock.unlock() }
            overlays.removeValue(forKey: token)
        }

        func revokeAll() {
            lock.lock()
            defer { lock.unlock() }
            overlays.removeAll()
        }

        func overlay(token: RendererFrameOriginToken, path: String) -> RendererFrameResource? {
            lock.lock()
            defer { lock.unlock() }
            return overlays[token]?[path]
        }
    }

    /// Serves the frame-scoped input bootstrap for one token, consumed when
    /// the entry document is served. Set by the reader at admission.
    private let bootstrapLookup: @Sendable (RendererFrameOriginToken) -> String?

    /// The host-composed frame resource layer, sharing the route table lock.
    private let composer: Composer

    /// Diagnostic record of every URL handed to `resource(for:)`. Read only
    /// from tests; production code never touches it.
    private(set) var diagnosticStartedRequests: [URL] = []

    init(bootstrapLookup: @escaping @Sendable (RendererFrameOriginToken) -> String? = { _ in nil }) {
        self.bootstrapLookup = bootstrapLookup
        self.composer = Composer(lock: lock)
    }

    /// Frame-scoped input bootstrap **JS** per admitted token, stored in the
    /// host frame-resource layer (not the route table). Served from the
    /// reserved `__host__/renderer-input.js` path: the package CSP blocks
    /// inline scripts, and WKUserScripts added post-load don't run in
    /// subframes.
    private func setInputBootstrap(token: RendererFrameOriginToken, javaScript: String) {
        composer.setInputBootstrap(token: token, javaScript: javaScript)
    }

    /// Attaches the frame-scoped input bootstrap to one admitted route. The
    /// host composer serves it as `__host__/renderer-input.js` and the entry
    /// document inlines a `<script src>` reference to that reserved path
    /// before the package's own scripts.
    func setFrameBootstrap(token: RendererFrameOriginToken, html: String) {
        setInputBootstrap(token: token, javaScript: html)
    }

    /// Revokes one frame's route and its host overlays. Later requests for
    /// that origin fail closed.
    func revoke(token: RendererFrameOriginToken) {
        lock.lock()
        defer { lock.unlock() }
        routes.removeValue(forKey: token)
        composer.revoke(token: token)
    }

    /// Admits one frame route and returns the frame-scoped entry URL to use
    /// as the iframe's `src`. The provider must be the validated package
    /// provider for the route's exact reservation.
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
            composer.setInputBootstrap(token: token, javaScript: inputBootstrapHTML)
        }
        return RendererFramePackageURL.frameURL(
            token: token,
            packageID: reservation.packageID,
            version: reservation.version,
            path: entryPath)
    }

    /// Revokes every route and host overlay (document replacement, snapshot
    /// replacement, reader dismantle). Active frames' requests fail closed.
    func revokeAll() {
        lock.lock()
        defer { lock.unlock() }
        routes.removeAll()
        composer.revokeAll()
    }

    var activeRouteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return routes.count
    }

    /// The canonical provider lookup. Reserved host-namespace paths are
    /// served from the frame-resource composer (typed host overlays); every
    /// other request is delegated unchanged to the validated package
    /// provider — package bytes are never synthesized or rewritten here.
    func resource(for url: URL) throws -> RendererPackageResource {
        let frameURL = try RendererFramePackageURL.parse(url)
        // Reserved host namespace: composed frame resources only. These
        // bytes are trusted host overlays, not package assets.
        if RendererFrameHostNamespace.isReserved(frameURL.request.path) {
            guard let overlay = composer.overlay(
                token: frameURL.token,
                path: frameURL.request.path.rawValue)
            else {
                DebugLog.reader("package-router: no host overlay for \(frameURL.request.path.rawValue) frame \(frameURL.token.rawValue)")
                throw RendererPackageResourceError.undeclaredAsset
            }
            return RendererPackageResource(
                data: overlay.data,
                mimeType: overlay.mimeType,
                isEntryDocument: false)
        }

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
        // Validated package file I/O runs outside the critical section. The
        // provider re-verifies the manifest declaration and digest per read.
        let provider = admitted.provider
        lock.unlock()
        let resource = try provider.resource(for: frameURL.canonicalURL)

        // Frame-resource composition: the entry document gains a reference to
        // the host input bootstrap under the reserved __host__/ namespace, so
        // the input selector exists before package scripts run. Composition
        // preserves package asset immutability — the validated provider's
        // bytes are never mutated, and the composed response is host overlay
        // plus package bytes; it does not match any package digest.
        guard resource.isEntryDocument,
              composer.overlay(token: frameURL.token, path: RendererFrameHostNamespace.inputBootstrapPath) != nil,
              let html = String(data: resource.data, encoding: .utf8),
              html.utf8.count <= RendererPackageValidationLimits.maximumCopiedByteCount
        else { return resource }

        let reference = "<script src=\"\(RendererFrameHostNamespace.inputBootstrapPath)\"></script>"
        var composed = html
        if let firstScriptRange = composed.lowercased().range(of: "<script") {
            composed.insert(contentsOf: reference, at: firstScriptRange.lowerBound)
        } else if let bodyEnd = composed.lowercased().range(of: "</body>") {
            composed.insert(contentsOf: reference, at: bodyEnd.lowerBound)
        } else {
            DebugLog.reader("package-router: entry document has no script or body tag; bootstrap reference not composed")
            return resource
        }
        return RendererPackageResource(
            data: Data(composed.utf8),
            mimeType: resource.mimeType,
            isEntryDocument: resource.isEntryDocument)
    }
}
#endif

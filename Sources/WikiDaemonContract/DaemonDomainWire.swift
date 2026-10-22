#if os(macOS)
import Foundation

// Versioned top-level envelope for every payload crossing the CLI ⇄ daemon
// socket (`SearchSocketWire` framing, one request/reply per connection — the
// socket file, flock guard, same-user gate, and deadlines are unchanged; only
// the payload gains this envelope). See `plans/cli-domain-commands.md`
// Phase 1.
//
// Shape: `{version, requestID, family, operation, payload?}` →
// `{version, requestID, family, operation, payload?, error?}`. `payload` is
// family-specific JSON bytes, so the established per-family wire values ride
// inside unchanged:
//
// - `hello`  — request payload nil; reply payload is `DaemonHelloPayload`
//   (version negotiation, served families, the daemon's build identity).
// - `search` — payload is the JSON `SearchRPCRequest` / `SearchRPCReply`
//   pair, byte-for-byte the values PR #1460 put on this socket.
// - `queue`  — payload is the JSON `QueueRPCEnvelope<Payload>` request/reply
//   bytes, so the queue error taxonomy (`QueueRPCErrorCode`) travels intact.
// - `wiki`   — registry + lifecycle operations (Phase 2; the dispatcher
//   serves it there). The case is reserved from v1 so the envelope shape
//   never changes; until served it answers a typed error.
//
// Dispatch contract: the daemon version-checks `version` BEFORE dispatching
// (mismatch → `unsupportedVersion`), then routes by `family` and
// `operation`. An unknown family string, unknown operation, or malformed
// payload is a typed `invalidRequest` REPLY inside this envelope — never a
// transport failure. Later phases (generic page/source/chat domain commands,
// typed CAS codes) extend this envelope by adding family cases and error
// codes; the framing and dispatch shape are frozen.

public enum DaemonDomainVersion {
    /// The envelope version this daemon serves and this client speaks.
    public static let current: UInt16 = 1
}

/// The command family inside one domain envelope. Adding a case is the
/// sanctioned extension point (Phase 3+ adds the generic domain-command
/// families); a family string the daemon does not decode is a typed
/// `invalidRequest` reply.
public enum DaemonDomainFamily: String, Codable, Sendable, CaseIterable {
    case hello
    case search
    case queue
    /// Wiki registry + lifecycle (Phase 2 of plans/cli-domain-commands.md).
    case wiki
    /// Read-only page commands executed daemon-side (Phase 3).
    case page
    /// Read-only source commands executed daemon-side (Phase 3).
    case source
    /// Read-only chat commands executed daemon-side (Phase 3).
    case chat
    /// Read-only bookmark commands executed daemon-side (Phase 3).
    case bookmark
    /// Read-only workspace commands executed daemon-side (Phase 3).
    case workspace
}

public struct DaemonDomainRequest: Codable, Equatable, Sendable {
    public let version: UInt16
    /// Echoed verbatim in the reply so a client can pair response to request.
    public let requestID: String
    public let family: DaemonDomainFamily
    /// Family-scoped verb (e.g. `search`, `queueSnapshot`, `listWikis`).
    public let operation: String
    /// Family-specific JSON payload; `nil` where the operation carries none.
    public let payload: Data?

    public init(
        version: UInt16 = DaemonDomainVersion.current,
        requestID: String,
        family: DaemonDomainFamily,
        operation: String,
        payload: Data? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.family = family
        self.operation = operation
        self.payload = payload
    }
}

public struct DaemonDomainReply: Codable, Equatable, Sendable {
    public let version: UInt16
    public let requestID: String
    public let family: DaemonDomainFamily
    public let operation: String
    /// Family-specific JSON payload on success; `nil` on failure (and for
    /// payload-less successes).
    public let payload: Data?
    /// Typed rejection; `nil` on success.
    public let error: DaemonDomainError?

    public init(
        version: UInt16 = DaemonDomainVersion.current,
        requestID: String,
        family: DaemonDomainFamily,
        operation: String,
        payload: Data? = nil,
        error: DaemonDomainError? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.family = family
        self.operation = operation
        self.payload = payload
        self.error = error
    }

    public static func success(
        requestID: String,
        family: DaemonDomainFamily,
        operation: String,
        payload: Data?
    ) -> Self {
        Self(
            requestID: requestID,
            family: family,
            operation: operation,
            payload: payload,
            error: nil)
    }

    public static func failure(
        requestID: String,
        family: DaemonDomainFamily?,
        operation: String,
        _ error: DaemonDomainError
    ) -> Self {
        Self(
            requestID: requestID,
            family: family ?? .hello,
            operation: operation,
            payload: nil,
            error: error)
    }
}

public enum DaemonDomainErrorCode: String, Codable, Sendable {
    /// Undecodable envelope, unknown family string, unknown operation, or a
    /// malformed family payload.
    case invalidRequest
    /// The envelope `version` is not one this daemon serves (checked before
    /// dispatch). A client seeing this (or a non-envelope reply) should run
    /// `hello` and tell the operator to relaunch/update the app.
    case unsupportedVersion
    /// The operation's target does not exist (e.g. no wiki matches a selector).
    case notFound
    /// The daemon build does not serve this family/operation (e.g. an
    /// engine-less build, or a phase not yet shipped).
    case unavailable
    /// The operation ran and failed; the daemon-side cause is in `message`.
    case operationFailed
}

public struct DaemonDomainError: Error, Codable, Equatable, Sendable, LocalizedError {
    public let code: DaemonDomainErrorCode
    public let message: String

    public init(code: DaemonDomainErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum DaemonDomainWire {
    public static func encode(_ request: DaemonDomainRequest) throws -> Data {
        try JSONEncoder().encode(request)
    }

    /// Decodes a request payload into the envelope. Every decode failure is a
    /// typed `invalidRequest` — the daemon answers these inside a reply, so a
    /// malformed frame can never masquerade as a transport fault.
    public static func decodeRequest(_ data: Data) throws -> DaemonDomainRequest {
        do {
            return try JSONDecoder().decode(DaemonDomainRequest.self, from: data)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "domain request could not be decoded: \(decodeReason(error))")
        }
    }

    public static func encode(_ reply: DaemonDomainReply) throws -> Data {
        try JSONEncoder().encode(reply)
    }

    /// Decodes a reply payload into the envelope. A decode failure here means
    /// the peer answered with something other than a domain envelope — with
    /// CLI and daemon shipped together this is an old daemon, so the error
    /// names the remedy instead of surfacing raw JSON noise.
    public static func decodeReply(_ data: Data) throws -> DaemonDomainReply {
        do {
            return try JSONDecoder().decode(DaemonDomainReply.self, from: data)
        } catch {
            throw DaemonDomainError(
                code: .unsupportedVersion,
                message: "the daemon did not answer with a domain envelope — the installed "
                    + "app is older than this CLI; quit and relaunch (or reinstall) the app")
        }
    }

    /// The daemons's `hello` capabilities answer (version negotiation).
    public static func decodeHelloPayload(_ data: Data) throws -> DaemonHelloPayload {
        do {
            return try JSONDecoder().decode(DaemonHelloPayload.self, from: data)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "hello capabilities payload could not be decoded")
        }
    }

    private static func decodeReason(_ error: Error) -> String {
        String(describing: error).prefix(200).description
    }
}

extension DaemonDomainRequest {
    /// The pre-dispatch version gate. Only the exact current version is
    /// served; anything else is a typed `unsupportedVersion` the client can
    /// turn into "requires app ≥ build N" guidance.
    public func requireCurrentVersion() throws {
        guard version == DaemonDomainVersion.current else {
            throw DaemonDomainError(
                code: .unsupportedVersion,
                message: "daemon serves domain protocol \(DaemonDomainVersion.current), "
                    + "request carried \(version)")
        }
    }
}

/// The `hello`/`capabilities` answer: what the daemon speaks and who built
/// it. A new CLI against an old daemon uses this to report "requires app ≥
/// build N" instead of a raw transport error.
public struct DaemonHelloPayload: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1

    public let version: UInt16
    /// The domain protocol version this daemon serves
    /// (`DaemonDomainVersion.current`).
    public let protocolVersion: UInt16
    /// Served families, sorted (e.g. `["hello", "queue", "search", "wiki"]`).
    public let families: [String]
    /// The daemon's app version / build number, when known (GeneratedVersion).
    public let appVersion: String?
    public let buildVersion: String?

    public init(
        version: UInt16 = Self.currentVersion,
        protocolVersion: UInt16,
        families: [String],
        appVersion: String?,
        buildVersion: String?
    ) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.families = families
        self.appVersion = appVersion
        self.buildVersion = buildVersion
    }
}

/// The `queue` family's lane-control request payload (`pauseQueue` /
/// `resumeQueue` / `haltQueue`). The value is the `QueueKind` raw string,
/// exactly what the XPC method carries today; the reply payload is the
/// `QueueRPCEnvelope<QueueVoidPayload>` bytes unchanged.
public struct DaemonQueueControlRequest: Codable, Equatable, Sendable {
    public let queue: String

    public init(queue: String) {
        self.queue = queue
    }
}

/// The family-scoped operation strings. Shared by the daemon dispatcher and
/// the CLI clients so a typo cannot split the two sides; new operations are
/// added here with their handler.
public enum DaemonDomainOperation {
    public enum Hello {
        /// Version negotiation: `DaemonHelloPayload` in the reply payload.
        public static let capabilities = "capabilities"
    }

    public enum Search {
        /// Payload: `SearchRPCRequest` bytes; reply payload:
        /// `SearchRPCReply` bytes.
        public static let search = "search"
    }

    public enum Queue {
        public static let queueSnapshot = "queueSnapshot"
        public static let enqueueItem = "enqueueItem"
        public static let pauseQueue = "pauseQueue"
        public static let resumeQueue = "resumeQueue"
        public static let haltQueue = "haltQueue"
        /// Phase 3: the durable per-wiki item read `wikictl job list/get` is
        /// built on (full terminal history, not the bounded snapshot window).
        public static let queueWikiItems = "queueWikiItems"
    }

    public enum Wiki {
        public static let listWikis = "listWikis"
        public static let createWiki = "createWiki"
        public static let deleteWiki = "deleteWiki"
        public static let renameWiki = "renameWiki"
        public static let resolveWiki = "resolveWiki"
    }

    // Phase 3 command families — the daemon EXECUTES the CLI's command layer
    // against its prepared services and replies with a uniform
    // `DaemonCommandOutcome` (stdout text or bytes + stderr + didCommit), so
    // byte-stable stdout is produced by the same code that produced it
    // in-process.

    public enum Page {
        public static let list = "list"
        public static let get = "get"
        public static let history = "history"
        public static let info = "info"
        public static let okfInspect = "okfInspect"
        public static let okfStatus = "okfStatus"
        public static let okfFreshness = "okfFreshness"
        public static let okfVerify = "okfVerify"
    }

    public enum Source {
        public static let list = "list"
        public static let cat = "cat"
        public static let export = "export"
        public static let info = "info"
    }

    public enum Chat {
        public static let list = "list"
        public static let get = "get"
        public static let search = "search"
    }

    public enum Bookmark {
        public static let list = "list"
    }

    public enum Workspace {
        public static let status = "status"
        public static let conflicts = "conflicts"
    }
}

// MARK: - wiki family payloads (Phase 2 of plans/cli-domain-commands.md)
//
// The wiki family routes the daemon's existing registry methods over the
// socket. Descriptor payloads are the daemon's own JSON `[WikiDescriptor]` /
// `WikiDescriptor` bytes (the same values the XPC methods carry), so the CLI
// decodes them with the shared `WikiDescriptor` type in WikiFSCore.

/// `createWiki` request payload. The daemon trims and defaults an empty name
/// to "Untitled Wiki" (the behavior the CLI's direct create path used to
/// implement).
public struct DaemonWikiCreateRequest: Codable, Equatable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// `deleteWiki` request payload. The id is the wiki's raw ULID string.
public struct DaemonWikiDeleteRequest: Codable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// `renameWiki` request payload.
public struct DaemonWikiRenameRequest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// `resolveWiki` request payload. The selector is a ULID id or a display
/// name (ULID tried first, mirroring `WikiResolver`).
public struct DaemonWikiResolveRequest: Codable, Equatable, Sendable {
    public let selector: String

    public init(selector: String) {
        self.selector = selector
    }
}
#endif

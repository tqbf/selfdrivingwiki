#if os(macOS)
import Foundation

// Typed request/reply wire for the daemon's unified search + autocomplete
// endpoint (`WikiDaemonProtocol.search(request:reply:)`). Values cross XPC
// JSON-encoded as `Data`; this module stays a Foundation-only leaf — no
// domain imports, no dependency cycles. Raw kind strings and the raw wiki
// ULID are decoded into typed values at each process boundary.
//
// The daemon owns one per-wiki search runtime behind this endpoint; a reply
// reflects every committed store write the daemon can observe, including
// writes made by other processes.

public enum SearchRPCVersion {
    public static let current: UInt16 = 1
}

public struct SearchRPCRequest: Codable, Equatable, Sendable {
    public let version: UInt16
    /// The wiki's raw ULID string.
    public let wikiID: String
    public let operation: SearchRPCOperation

    public init(
        version: UInt16 = SearchRPCVersion.current,
        wikiID: String,
        operation: SearchRPCOperation
    ) {
        self.version = version
        self.wikiID = wikiID
        self.operation = operation
    }
}

/// One operation per request, encoded as a single-key object (synthesized
/// `Codable`): `{"search": {"query": …, "kinds": […], "limit": N}}` or
/// `{"autocomplete": {"partial": …, "kinds": …, "distance": N, "limit": N}}`.
/// `kinds` `nil` or empty means all kinds; `distance` is clamped to `0...255`
/// by the daemon.
public enum SearchRPCOperation: Codable, Equatable, Sendable {
    case search(query: String, kinds: [String]?, limit: Int)
    case autocomplete(partial: String, kinds: [String]?, distance: Int, limit: Int)
}

public struct SearchRPCHit: Codable, Equatable, Sendable {
    /// The composite search document id `"<kind>:<ULID>"`.
    public let documentID: String
    /// Raw kind string: `"page"` / `"source"` / `"chat"`.
    public let kind: String
    public let title: String
    public let score: Double

    public init(documentID: String, kind: String, title: String, score: Double) {
        self.documentID = documentID
        self.kind = kind
        self.title = title
        self.score = score
    }
}

public struct SearchRPCReply: Codable, Equatable, Sendable {
    public let version: UInt16
    /// Present on success (`[]` = no matches); `nil` on failure.
    public let hits: [SearchRPCHit]?
    /// Present on failure; `nil` on success.
    public let error: SearchRPCError?

    public init(
        version: UInt16 = SearchRPCVersion.current,
        hits: [SearchRPCHit]?,
        error: SearchRPCError?
    ) {
        self.version = version
        self.hits = hits
        self.error = error
    }

    public static func success(_ hits: [SearchRPCHit]) -> Self {
        Self(hits: hits, error: nil)
    }

    public static func failure(_ code: SearchRPCErrorCode, _ message: String) -> Self {
        Self(hits: nil, error: SearchRPCError(code: code, message: message))
    }
}

public enum SearchRPCErrorCode: String, Codable, Sendable {
    case invalidRequest
    case unsupportedVersion
    case unknownWiki
    case unavailable
    case operationFailed
}

public struct SearchRPCError: Error, Codable, Equatable, Sendable {
    public let code: SearchRPCErrorCode
    public let message: String

    public init(code: SearchRPCErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum SearchRPCWire {
    public static func encode(_ request: SearchRPCRequest) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public static func decode(_ data: Data) throws -> SearchRPCRequest {
        let request: SearchRPCRequest
        do {
            request = try JSONDecoder().decode(SearchRPCRequest.self, from: data)
        } catch {
            throw SearchRPCError(code: .invalidRequest, message: "Search request could not be decoded")
        }
        guard request.version == SearchRPCVersion.current else {
            throw SearchRPCError(
                code: .unsupportedVersion,
                message: "Unsupported search RPC version: \(request.version)")
        }
        return request
    }

    public static func encode(_ reply: SearchRPCReply) throws -> Data {
        try JSONEncoder().encode(reply)
    }
}
#endif

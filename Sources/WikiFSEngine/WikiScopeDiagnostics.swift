import Cordis
import Foundation
import WikiFSTypes

public enum WikiScopeHostAssociation: Sendable, Equatable {
    case app
    case daemon(cacheKey: WikiID)
}

public struct WikiScopeIdentitySnapshot: Sendable, Equatable {
    public let scope: ScopeDiagnosticsSnapshot
    public let profileWikiID: WikiID
    public let sessionWikiID: WikiID?
    public let storeWikiID: WikiID?
    public let eventBusWikiID: WikiID?
    public let databaseWikiID: WikiID?
    public let host: WikiScopeHostAssociation

    public init(
        scope: ScopeDiagnosticsSnapshot,
        profileWikiID: WikiID,
        sessionWikiID: WikiID? = nil,
        storeWikiID: WikiID? = nil,
        eventBusWikiID: WikiID? = nil,
        databaseWikiID: WikiID? = nil,
        host: WikiScopeHostAssociation
    ) {
        self.scope = scope
        self.profileWikiID = profileWikiID
        self.sessionWikiID = sessionWikiID
        self.storeWikiID = storeWikiID
        self.eventBusWikiID = eventBusWikiID
        self.databaseWikiID = databaseWikiID
        self.host = host
    }

    public func validate(sink: any InvariantViolationSink) {
        guard case .wiki(let scopeWikiID) = scope.descriptor else {
            sink.record(InvariantViolation(
                code: "wiki.identity.scope-descriptor",
                owner: InvariantOwners.wikiIdentity,
                message: "The wiki profile does not have a wiki scope descriptor.",
                scope: scope))
            return
        }
        let identities: [(String, WikiID?)] = [
            ("profile", profileWikiID),
            ("session", sessionWikiID),
            ("store", storeWikiID),
            ("event bus", eventBusWikiID),
            ("database", databaseWikiID),
        ]
        for (label, identity) in identities where identity != nil && identity != scopeWikiID {
            sink.record(InvariantViolation(
                code: "wiki.identity.mismatch",
                owner: InvariantOwners.wikiIdentity,
                message: "The \(label) wiki ID differs from the scope wiki ID.",
                scope: scope))
        }
        if case .daemon(let cacheKey) = host, cacheKey != scopeWikiID {
            sink.record(InvariantViolation(
                code: "wiki.identity.daemon-cache",
                owner: InvariantOwners.wikiIdentity,
                message: "The daemon cache key differs from the scope wiki ID.",
                scope: scope))
        }
    }
}

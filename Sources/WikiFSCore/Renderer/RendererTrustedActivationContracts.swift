import Foundation

// pattern: Functional Core

/// A host-normalized external HTTP(S) destination. Page URLs are normalized at
/// the native boundary before they can be bound to or redeemed by a nonce.
public struct RendererExternalDestination: Hashable, Sendable {
    public let url: URL

    public init?(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), host.isEmpty == false,
              components.user == nil,
              components.password == nil
        else { return nil }

        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        guard let normalized = components.url else { return nil }
        self.url = normalized
    }
}

public struct RendererExternalActivationNonce: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

public protocol RendererActivationClock {
    func now() -> Date
}

public struct SystemRendererActivationClock: RendererActivationClock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol RendererActivationNonceGenerating {
    func makeNonce() -> RendererExternalActivationNonce
}

/// Uses the system random-number generator, which is seeded from operating
/// system entropy, to create 256-bit opaque activation tokens.
public struct SystemRendererActivationNonceGenerator: RendererActivationNonceGenerating {
    public init() {}

    public func makeNonce() -> RendererExternalActivationNonce {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<WikiAppWebViewPolicy.externalActivationNonceByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        return .init(rawValue: Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ""))
    }
}

public struct RendererExternalActivationContext: Equatable, Sendable {
    public let sessionID: RendererSessionID
    public let windowID: UUID
    public let frameID: UUID
    public let mainFrameID: UUID
    public let navigationID: UInt64

    public init(sessionID: RendererSessionID, windowID: UUID, frameID: UUID, mainFrameID: UUID, navigationID: UInt64) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.frameID = frameID
        self.mainFrameID = mainFrameID
        self.navigationID = navigationID
    }
}

public enum RendererExternalActivationError: Error, Equatable, Sendable {
    case absentNonce
    case expiredNonce
    case replayedNonce
    case destinationMismatch
    case wrongSession
    case wrongWindow
    case nonMainFrame
    case navigationInvalidated
    case sessionFailed
    case sessionClosed
    case capacityEvictedNonce
}

/// Session-local, one-use authorization state for externally opened URLs.
/// Its callers supply only host-observed contexts; it accepts no page claims
/// about timestamps, trusted events, or synthetic-event status.
public struct RendererExternalActivationAuthorizer {
    private struct PendingActivation {
        let destination: RendererExternalDestination
        let context: RendererExternalActivationContext
        let issuanceOrder: UInt64
        let expiresAt: Date
    }

    private struct InvalidatedActivation {
        let error: RendererExternalActivationError
        let invalidationOrder: UInt64
    }

    private let clock: any RendererActivationClock
    private let nonceGenerator: any RendererActivationNonceGenerating
    private var pending: [RendererExternalActivationNonce: PendingActivation] = [:]
    private var invalidated: [RendererExternalActivationNonce: InvalidatedActivation] = [:]
    private var nextIssuanceOrder: UInt64 = 0
    private var nextInvalidationOrder: UInt64 = 0

    public init(
        clock: any RendererActivationClock = SystemRendererActivationClock(),
        nonceGenerator: any RendererActivationNonceGenerating = SystemRendererActivationNonceGenerator()
    ) {
        self.clock = clock
        self.nonceGenerator = nonceGenerator
    }

    public mutating func recordTrustedActivation(
        destination: RendererExternalDestination,
        context: RendererExternalActivationContext
    ) -> RendererExternalActivationNonce {
        let now = clock.now()
        invalidateExpiredPending(at: now)
        evictOldestPendingActivationsUntilWithinLimit()
        let nonce = nonceGenerator.makeNonce()
        nextIssuanceOrder &+= 1
        pending[nonce] = PendingActivation(
            destination: destination,
            context: context,
            issuanceOrder: nextIssuanceOrder,
            expiresAt: now.addingTimeInterval(WikiAppWebViewPolicy.externalActivationNonceLifetime.timeInterval)
        )
        return nonce
    }

    public mutating func redeem(
        nonce: RendererExternalActivationNonce?,
        destination: RendererExternalDestination,
        context: RendererExternalActivationContext
    ) throws -> RendererExternalDestination {
        guard let nonce else { throw RendererExternalActivationError.absentNonce }
        if let invalidation = invalidated[nonce] { throw invalidation.error }
        guard let activation = pending[nonce] else { throw RendererExternalActivationError.absentNonce }
        guard clock.now() < activation.expiresAt else {
            invalidate(nonce, reason: .expiredNonce)
            throw RendererExternalActivationError.expiredNonce
        }
        guard activation.context.sessionID == context.sessionID else {
            invalidate(nonce, reason: .wrongSession)
            throw RendererExternalActivationError.wrongSession
        }
        guard activation.context.windowID == context.windowID else {
            invalidate(nonce, reason: .wrongWindow)
            throw RendererExternalActivationError.wrongWindow
        }
        guard context.frameID == context.mainFrameID,
              activation.context.frameID == activation.context.mainFrameID
        else {
            invalidate(nonce, reason: .nonMainFrame)
            throw RendererExternalActivationError.nonMainFrame
        }
        guard activation.context.navigationID == context.navigationID else {
            invalidate(nonce, reason: .navigationInvalidated)
            throw RendererExternalActivationError.navigationInvalidated
        }
        guard activation.destination == destination else {
            invalidate(nonce, reason: .destinationMismatch)
            throw RendererExternalActivationError.destinationMismatch
        }
        invalidate(nonce, reason: .replayedNonce)
        return activation.destination
    }

    public mutating func invalidateAll(reason: RendererExternalActivationError) {
        let nonces = Array(pending.keys)
        for nonce in nonces { invalidate(nonce, reason: reason) }
    }

    private mutating func invalidate(_ nonce: RendererExternalActivationNonce, reason: RendererExternalActivationError) {
        pending.removeValue(forKey: nonce)
        nextInvalidationOrder &+= 1
        invalidated[nonce] = .init(error: reason, invalidationOrder: nextInvalidationOrder)
        retainBoundedInvalidatedActivations()
    }

    private mutating func invalidateExpiredPending(at now: Date) {
        let expiredNonces = pending.compactMap { nonce, activation in
            activation.expiresAt <= now ? nonce : nil
        }
        for nonce in expiredNonces { invalidate(nonce, reason: .expiredNonce) }
    }

    private mutating func evictOldestPendingActivationsUntilWithinLimit() {
        while pending.count >= WikiAppWebViewPolicy.maximumPendingExternalActivationNonces,
              let oldestNonce = pending.min(by: { $0.value.issuanceOrder < $1.value.issuanceOrder })?.key {
            invalidate(oldestNonce, reason: .capacityEvictedNonce)
        }
        retainBoundedInvalidatedActivations()
    }

    private mutating func retainBoundedInvalidatedActivations() {
        let overflow = invalidated.count - WikiAppWebViewPolicy.maximumInvalidatedExternalActivationNonces
        guard overflow > 0 else { return }
        let oldestNonces = invalidated
            .sorted { $0.value.invalidationOrder < $1.value.invalidationOrder }
            .prefix(overflow)
            .map(\.key)
        for nonce in oldestNonces { invalidated.removeValue(forKey: nonce) }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

import Foundation

// pattern: Functional Core

public struct RendererSessionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public enum WikiAppWebViewPolicy {
    public static let maximumConcurrentSessions = 4
    public static let maximumSourceByteCount = 32 * 1_024 * 1_024
    public static let maximumDecodedByteCount = RendererPackageValidationLimits.maximumDecodedInputByteCount
    public static let maximumBridgeMessageByteCount = 64 * 1_024
    /// JSON and Base64 response framing need room inside the message limit.
    public static let maximumBridgeResponseMetadataByteCount = 1 * 1_024
    public static let maximumBridgeInputPayloadByteCount =
        ((maximumBridgeMessageByteCount - maximumBridgeResponseMetadataByteCount) / 4) * 3
    public static let maximumBridgeRequestIDByteCount = 256
    public static let maximumRetainedBridgeRequestIDs = 1_024
    public static let maximumNamedContentPathByteCount = 256
    public static let maximumNamedContentSubpathByteCount = 16 * 1_024
    /// Max byte count of a single validated asset reference (the `asset.read`
    /// key). Bounded so admission lookups and replay budgets stay small.
    public static let maximumAssetReferenceByteCount = 256
    public static let externalActivationNonceByteCount = 32
    public static let externalActivationNonceLifetime: Duration = .seconds(15)
    /// Per-session cap for active external activation capabilities.
    public static let maximumPendingExternalActivationNonces = 64
    /// Bounded diagnostic/tombstone retention; removed entries are still never redeemable.
    public static let maximumInvalidatedExternalActivationNonces = 256
    public static let loadTimeout: Duration = .seconds(30)
    public static let isolatedContentWorldNamePrefix = "com.selfdrivingwiki.renderer-host"
    public static let isolatedMessageHandlerName = "renderer-host"
    public static let trustedActivationHandlerName = "renderer-trusted-activation"
    public static let externalLinkHandlerName = "renderer-external-link"
    public static let hostNavigationActivationHandlerName = "renderer-host-navigation-activation"
}

/// Host policy for the optional external-browser activation capability.
///
/// The default is deliberately disabled: a renderer page can choose an anchor
/// destination, so installing this capability is an explicit host decision
/// rather than an ambient property of every WebView session.
public enum RendererExternalActivationPolicy: Equatable, Sendable {
    case disabled
    case enabled
}

public enum RendererSessionFailureKind: Equatable, Sendable {
    case invalidEntryURL
    case concurrencyLimitReached
    case loadTimedOut
    case navigationFailed
    case bridgeBootstrapFailed
    case webContentProcessTerminated

    /// Only failures caused by executable installed renderer code may affect
    /// the machine safe-mode window. Rejection and lifecycle paths deliberately
    /// have no mapping and therefore cannot be persisted as failures.
    public var installedRendererFailureCause: RendererInstalledRendererFailureCause? {
        switch self {
        case .loadTimedOut:
            .loadTimedOut
        case .navigationFailed:
            .entryNavigationFailed
        case .bridgeBootstrapFailed:
            .bridgeBootstrapFailed
        case .webContentProcessTerminated:
            .webContentProcessTerminated
        case .invalidEntryURL, .concurrencyLimitReached:
            nil
        }
    }
}

public struct RendererSessionFailure: Equatable, Sendable {
    public let sessionID: RendererSessionID
    public let kind: RendererSessionFailureKind

    public init(sessionID: RendererSessionID, kind: RendererSessionFailureKind) {
        self.sessionID = sessionID
        self.kind = kind
    }
}

/// Async host seam for recording one terminal failure of an installed package.
/// A session invokes this only after it makes a counted terminal transition.
public typealias RendererSessionFailureRecording = @Sendable (
    RendererSessionFailure,
    RendererPackageReservation
) async -> Void

public enum WikiAppWebViewSessionState: Equatable, Sendable {
    case idle(RendererSessionID)
    case loading(RendererSessionID)
    case ready(RendererSessionID)
    case failed(RendererSessionFailure)
    case closed(RendererSessionID)
}

public struct WikiAppWebViewSessionStateMachine: Equatable, Sendable {
    public private(set) var state: WikiAppWebViewSessionState

    public init(sessionID: RendererSessionID) { state = .idle(sessionID) }

    @discardableResult
    public mutating func start() -> Bool {
        guard case .idle = state else { return false }
        state = .loading(sessionID)
        return true
    }

    public mutating func markReady(sessionID: RendererSessionID) {
        guard case let .loading(loadingID) = state, loadingID == sessionID else { return }
        state = .ready(sessionID)
    }

    @discardableResult
    public mutating func fail(sessionID: RendererSessionID, kind: RendererSessionFailureKind) -> Bool {
        switch state {
        case let .loading(loadingID) where loadingID == sessionID:
            state = .failed(.init(sessionID: sessionID, kind: kind))
            return true
        case let .ready(readyID) where readyID == sessionID && kind == .webContentProcessTerminated:
            state = .failed(.init(sessionID: sessionID, kind: kind))
            return true
        default:
            return false
        }
    }

    @discardableResult
    public mutating func close() -> Bool {
        guard case .closed = state else {
            state = .closed(sessionID)
            return true
        }
        return false
    }

    public var sessionID: RendererSessionID {
        switch state {
        case let .idle(value), let .loading(value), let .ready(value), let .closed(value): value
        case let .failed(failure): failure.sessionID
        }
    }
}

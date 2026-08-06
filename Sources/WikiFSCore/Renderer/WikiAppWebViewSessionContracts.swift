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
    public static let loadTimeout: Duration = .seconds(30)
    public static let isolatedContentWorldName = "com.selfdrivingwiki.renderer-host"
    public static let isolatedMessageHandlerName = "renderer-host"
}

public enum RendererSessionFailureKind: Equatable, Sendable {
    case invalidEntryURL
    case concurrencyLimitReached
    case loadTimedOut
    case navigationFailed
    case webContentProcessTerminated
}

public struct RendererSessionFailure: Equatable, Sendable {
    public let sessionID: RendererSessionID
    public let kind: RendererSessionFailureKind

    public init(sessionID: RendererSessionID, kind: RendererSessionFailureKind) {
        self.sessionID = sessionID
        self.kind = kind
    }
}

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

    public mutating func fail(sessionID: RendererSessionID, kind: RendererSessionFailureKind) {
        guard case let .loading(loadingID) = state, loadingID == sessionID else { return }
        state = .failed(.init(sessionID: sessionID, kind: kind))
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

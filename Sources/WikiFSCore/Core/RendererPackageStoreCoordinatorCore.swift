import Foundation

// pattern: Functional Core

/// Injected wall clock for package-store ownership records and deterministic tests.
public protocol RendererCoordinatorClock: Sendable {
    func now() -> Date
}

public struct SystemRendererCoordinatorClock: RendererCoordinatorClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Process facts written to an ownership record. These values identify a process,
/// not a package payload or a filesystem location.
public struct RendererProcessIdentity: Codable, Equatable, Sendable {
    public let processID: Int32
    public let executableIdentity: String
    public let hostIdentity: String
    public let bootSessionIdentity: String?

    public init(processID: Int32, executableIdentity: String, hostIdentity: String, bootSessionIdentity: String?) {
        self.processID = processID
        self.executableIdentity = executableIdentity
        self.hostIdentity = hostIdentity
        self.bootSessionIdentity = bootSessionIdentity
    }

    public static func current() -> Self {
        Self(
            processID: ProcessInfo.processInfo.processIdentifier,
            executableIdentity: ProcessInfo.processInfo.processName,
            hostIdentity: ProcessInfo.processInfo.hostName,
            bootSessionIdentity: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
        )
    }
}

public protocol RendererProcessLivenessChecking: Sendable {
    func isLive(_ identity: RendererProcessIdentity) -> Bool
}

public struct SystemRendererProcessLivenessChecker: RendererProcessLivenessChecking {
    public init() {}
    public func isLive(_ identity: RendererProcessIdentity) -> Bool {
        guard identity.hostIdentity == ProcessInfo.processInfo.hostName else { return false }
        return kill(identity.processID, 0) == 0 || errno == EPERM
    }
}

public protocol RendererCoordinatorOwnerTokenGenerating: Sendable {
    func nextOwnerToken() -> String
}

public struct UUIDRendererCoordinatorOwnerTokenGenerator: RendererCoordinatorOwnerTokenGenerating {
    public init() {}
    public func nextOwnerToken() -> String { UUID().uuidString.lowercased() }
}

struct RendererCoordinatorOwnerRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let processIdentity: RendererProcessIdentity
    let startedAt: Date
    let heartbeatAt: Date
    let ownerToken: String

    init(processIdentity: RendererProcessIdentity, now: Date, ownerToken: String) throws {
        guard Self.isValidToken(ownerToken) else { throw RendererCoordinatorFailure.invalidOwnerToken }
        schemaVersion = 1
        self.processIdentity = processIdentity
        startedAt = now
        heartbeatAt = now
        self.ownerToken = ownerToken
    }

    func isExpired(at now: Date, policy: RendererEventPolicy) -> Bool {
        heartbeatAt.addingTimeInterval(policy.leaseExpiry + policy.clockSkewSafetyMargin) < now
    }

    static func decode(_ data: Data) throws -> Self {
        let record: Self
        do { record = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RendererCoordinatorFailure.malformedOwnerRecord }
        guard record.schemaVersion == 1,
              record.startedAt <= record.heartbeatAt,
              Self.isValidToken(record.ownerToken)
        else { throw RendererCoordinatorFailure.malformedOwnerRecord }
        return record
    }

    private static func isValidToken(_ token: String) -> Bool {
        token.count >= 16 && token.count <= 128 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// Redacted coordinator diagnostics. These deliberately exclude lock contents and
/// absolute filesystem paths because ownership records can originate externally.
public enum RendererCoordinatorFailure: Error, Equatable, Sendable {
    case invalidOwnerToken
    case malformedOwnerRecord
    case lockAcquisitionTimedOut
    case staleOwnerStillLive
    case lockIdentityChanged
    case lockOwnershipChanged
    case lockCleanupFailed
    case filesystemOperationFailed
}

func rendererCoordinatorShouldRecover(
    owner: RendererCoordinatorOwnerRecord,
    now: Date,
    policy: RendererEventPolicy,
    livenessChecker: some RendererProcessLivenessChecking
) throws -> Bool {
    guard owner.isExpired(at: now, policy: policy) else { return false }
    guard livenessChecker.isLive(owner.processIdentity) == false else {
        throw RendererCoordinatorFailure.staleOwnerStillLive
    }
    return true
}

import Foundation
import WikiFSTypes

public struct InvariantOwner: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }
}

public struct InvariantCode: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }
}

public enum InvariantOwners {
    public static let wikiIdentity: InvariantOwner = "wiki.identity"
    public static let scopeLifecycle: InvariantOwner = "scope.lifecycle"
    public static let wikiEvents: InvariantOwner = "wiki.events"
    public static let processOwnership: InvariantOwner = "process.ownership"
}

public struct InvariantViolation: Sendable, Equatable {
    public let code: InvariantCode
    public let owner: InvariantOwner
    public let message: String
    public let scope: ScopeDiagnosticsSnapshot?

    public init(
        code: InvariantCode,
        owner: InvariantOwner,
        message: String,
        scope: ScopeDiagnosticsSnapshot? = nil
    ) {
        self.code = code
        self.owner = owner
        self.message = message
        self.scope = scope
    }
}

public protocol InvariantViolationSink: Sendable {
    func record(_ violation: InvariantViolation)
}

// The private lock protects the complete recorded array on every read and write.
// swiftlint:disable:next unchecked_sendable
public final class RecordingInvariantViolationSink: InvariantViolationSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [InvariantViolation] = []

    public init() {}

    public func record(_ violation: InvariantViolation) {
        lock.lock()
        recorded.append(violation)
        lock.unlock()
    }

    public func violations() -> [InvariantViolation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

public struct DebugLogInvariantViolationSink: InvariantViolationSink {
    public init() {}

    public func record(_ violation: InvariantViolation) {
        DebugLog.store(
            "Invariant violation [\(violation.code.rawValue)] owner=\(violation.owner.rawValue): \(violation.message)")
    }
}

public struct InvariantFilterConfiguration: Sendable, Equatable {
    public let enabled: Bool
    public let allowlist: [String]
    public let blocklist: [String]

    public init(enabled: Bool = true, allowlist: [String] = [], blocklist: [String] = []) {
        self.enabled = enabled
        self.allowlist = allowlist
        self.blocklist = blocklist
    }
}

public enum InvariantRegistryError: Error, Sendable, Equatable {
    case blankPattern
    case paddedPattern(String)
    case duplicatePattern(String)
    case invalidPattern(String)
    case duplicateOwner(InvariantOwner)
    case installerFailed(InvariantOwner)
}

public struct InvariantInstaller: Sendable {
    public let owner: InvariantOwner
    public let dependencies: [ServiceDependency]
    private let installBody: @Sendable (ActivationContext) async throws -> Void

    public init(
        owner: InvariantOwner,
        dependencies: [ServiceDependency] = [],
        install: @escaping @Sendable (ActivationContext) async throws -> Void
    ) {
        self.owner = owner
        self.dependencies = dependencies
        self.installBody = install
    }

    fileprivate func definition() throws -> ComponentDefinition {
        try ComponentDefinition(
            label: "invariant.\(owner.rawValue)",
            dependencies: dependencies,
            activation: installBody)
    }
}

public actor InvariantRegistration: Sendable {
    private var context: CordisContext?
    private let owner: InvariantOwner?
    private let registry: InvariantRegistry?

    fileprivate init(
        context: CordisContext?,
        owner: InvariantOwner? = nil,
        registry: InvariantRegistry? = nil
    ) {
        self.context = context
        self.owner = owner
        self.registry = registry
    }

    public func dispose() async throws {
        guard let owned = context, let owner, let registry else { return }
        context = nil
        try await registry.dispose(owner: owner, context: owned)
    }
}

public actor InvariantRegistry {
    public let sink: any InvariantViolationSink
    private let root: CordisContext
    private let configuration: InvariantFilterConfiguration
    private var owners: Set<InvariantOwner> = []

    public init(
        root: CordisContext,
        configuration: InvariantFilterConfiguration = .init(),
        sink: any InvariantViolationSink
    ) throws {
        try Self.validate(configuration.allowlist + configuration.blocklist)
        self.root = root
        self.configuration = configuration
        self.sink = sink
    }

    public func register(_ installer: InvariantInstaller) async throws -> InvariantRegistration {
        guard owners.insert(installer.owner).inserted else {
            throw InvariantRegistryError.duplicateOwner(installer.owner)
        }
        guard isSelected(installer.owner) else {
            owners.remove(installer.owner)
            return InvariantRegistration(context: nil)
        }

        let child: CordisContext
        do {
            child = try await root.child()
        } catch {
            owners.remove(installer.owner)
            throw error
        }

        do {
            let handle = try await child.register(installer.definition())
            let state = try await handle.awaitSettled()
            guard state.kind == .active else {
                throw InvariantRegistryError.installerFailed(installer.owner)
            }
        } catch {
            do {
                try await child.dispose()
            } catch let cleanupError {
                sink.record(InvariantViolation(
                    code: "registry.install-cleanup",
                    owner: installer.owner,
                    message: "Installer cleanup failed: \(cleanupError)"))
            }
            owners.remove(installer.owner)
            throw error
        }

        return InvariantRegistration(context: child, owner: installer.owner, registry: self)
    }

    fileprivate func dispose(owner: InvariantOwner, context: CordisContext) async throws {
        guard owners.contains(owner) else { return }
        do {
            try await context.dispose()
            owners.remove(owner)
        } catch {
            owners.remove(owner)
            throw error
        }
    }

    public func activeOwners() -> Set<InvariantOwner> { owners }

    private func isSelected(_ owner: InvariantOwner) -> Bool {
        guard configuration.enabled else { return false }
        let value = owner.rawValue
        if configuration.blocklist.contains(where: { Self.matches($0, value) }) { return false }
        return configuration.allowlist.isEmpty
            || configuration.allowlist.contains(where: { Self.matches($0, value) })
    }

    private static func validate(_ patterns: [String]) throws {
        var seen: Set<String> = []
        for pattern in patterns {
            guard !pattern.isEmpty else { throw InvariantRegistryError.blankPattern }
            guard pattern == pattern.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw InvariantRegistryError.paddedPattern(pattern)
            }
            guard pattern.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "*" }),
                  pattern.filter({ $0 == "*" }).count <= 1,
                  !pattern.dropLast().contains("*") else {
                throw InvariantRegistryError.invalidPattern(pattern)
            }
            guard seen.insert(pattern).inserted else {
                throw InvariantRegistryError.duplicatePattern(pattern)
            }
        }
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        if pattern.hasSuffix("*") { return value.hasPrefix(String(pattern.dropLast())) }
        return pattern == value
    }
}

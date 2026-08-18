import Foundation

/// The public finite state for one component declaration.
public enum ComponentState: Equatable, Sendable {
    case pending(generation: UInt64)
    case loading(generation: UInt64)
    case active(generation: UInt64)
    case unloading(generation: UInt64)
    case failed(generation: UInt64, failure: CordisFailure)
    case disposed(generation: UInt64)

    public enum Kind: String, Equatable, Sendable {
        case pending
        case loading
        case active
        case unloading
        case failed
        case disposed
    }

    public var kind: Kind {
        switch self {
        case .pending: .pending
        case .loading: .loading
        case .active: .active
        case .unloading: .unloading
        case .failed: .failed
        case .disposed: .disposed
        }
    }

    public var generation: UInt64 {
        switch self {
        case .pending(let generation), .loading(let generation), .active(let generation),
             .unloading(let generation), .failed(let generation, _), .disposed(let generation):
            generation
        }
    }

    public var isSettled: Bool {
        switch self {
        case .loading, .unloading:
            false
        case .pending, .active, .failed, .disposed:
            true
        }
    }
}

/// A deterministic diagnostic for a component that cannot activate.
public struct ComponentDiagnostic: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case missingDependencies([ServiceDescriptor])
        case possibleDependencyCycle([ServiceDescriptor])
        case failed(CordisFailure)
    }

    public let componentID: ComponentID
    public let label: String
    public let reason: Reason

    public init(componentID: ComponentID, label: String, reason: Reason) {
        self.componentID = componentID
        self.label = label
        self.reason = reason
    }
}

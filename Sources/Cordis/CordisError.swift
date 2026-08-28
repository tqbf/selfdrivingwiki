import Foundation

public struct ComponentID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ContextID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ProviderID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct EffectID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct CordisFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let typeName: String
    public let message: String

    public init(_ message: String) {
        typeName = String(reflecting: CordisFailure.self)
        self.message = message
    }

    public init(_ error: any Error) {
        typeName = String(reflecting: type(of: error))
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
    }

    public var description: String { message }
}

public struct CleanupFailure: Equatable, Sendable {
    public let effectID: EffectID
    public let error: CordisFailure

    public init(effectID: EffectID, error: CordisFailure) {
        self.effectID = effectID
        self.error = error
    }
}

public struct CleanupAggregateError: Error, Equatable, Sendable {
    public let failures: [CleanupFailure]

    public init(failures: [CleanupFailure]) {
        self.failures = failures
    }
}

public enum CordisError: Error, Equatable, Sendable {
    case missingService(ServiceDescriptor)
    case duplicateSupply(ServiceDescriptor)
    case disposedContext(ContextID)
    case disposedComponent(ComponentID)
    case inactiveActivation(ComponentID)
    case inactiveProvider(ProviderID)
    case inactiveEffect(EffectID)
    case activationFailure(componentID: ComponentID, failure: CordisFailure)
    case invalidDefinition(componentID: ComponentID, reason: String)
    case cycle(componentID: ComponentID, service: ServiceDescriptor?)
    case invalidTransition(componentID: ComponentID, from: ComponentState.Kind, to: ComponentState.Kind)
    case cleanup(CleanupAggregateError)
    case typeMismatch(ServiceDescriptor)
    case eventPayloadMismatch(EventDescriptor)
    case eventListenerMismatch(EventDescriptor)
    case eventModeMismatch(EventDescriptor)
    case unknownListener(ListenerID)
    case duplicatePlugin(PluginID)
    case reservedPluginID(PluginID)
    case invalidConfig(pluginID: PluginID, entryID: String?, issues: [ConfigIssue])
}

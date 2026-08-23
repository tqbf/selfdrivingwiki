import Cordis
import Foundation

/// Stable identity for one registered tool.
public struct ToolName: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

/// JSON-compatible schema text advertised for one tool's input.
public struct ToolDescriptor: Hashable, Sendable {
    public let name: ToolName
    public let description: String
    public let inputSchema: String

    public init(name: ToolName, description: String, inputSchema: String) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// One callable tool registered with the process-scoped registry.
public struct RegisteredTool: Sendable {
    public typealias Execute = @Sendable (_ payload: String) async throws -> String

    public let descriptor: ToolDescriptor
    private let executePayload: Execute

    public init(descriptor: ToolDescriptor, execute: @escaping Execute) {
        self.descriptor = descriptor
        self.executePayload = execute
    }

    public func execute(payload: String) async throws -> String {
        try await executePayload(payload)
    }
}

public enum ToolRuntimeError: Error, Equatable, Sendable {
    case duplicateTool(ToolName)
    case unknownTool(ToolName)
    case missingExecutionResult(ToolName)
}

/// Mutable payload passed through the guarded tool-execution waterfalls.
public struct ToolExecutionContext: Sendable, Equatable {
    public let name: ToolName
    public var payload: String
    public var result: String?

    public init(name: ToolName, payload: String, result: String? = nil) {
        self.name = name
        self.payload = payload
        self.result = result
    }
}

/// A reversible, token-owned tool registration.
public struct ToolRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

/// Process-scoped registry. Token ownership prevents a stale disposer from
/// removing a later registration with the same name.
public actor ToolRegistry {
    private struct Registration: Sendable {
        let token: UUID
        let tool: RegisteredTool
    }

    private var registrations: [ToolName: Registration] = [:]

    public init() {}

    public func register(_ tool: RegisteredTool) throws -> ToolRegistration {
        let name = tool.descriptor.name
        guard registrations[name] == nil else {
            throw ToolRuntimeError.duplicateTool(name)
        }
        let token = UUID()
        registrations[name] = Registration(token: token, tool: tool)
        return ToolRegistration { [weak self] in
            await self?.remove(name: name, token: token)
        }
    }

    public func resolve(_ name: ToolName) -> RegisteredTool? {
        registrations[name]?.tool
    }

    public func descriptors() -> [ToolDescriptor] {
        registrations.values.map(\.tool.descriptor).sorted {
            $0.name.rawValue < $1.name.rawValue
        }
    }

    private func remove(name: ToolName, token: UUID) {
        guard registrations[name]?.token == token else { return }
        registrations.removeValue(forKey: name)
    }
}

/// Executes registered tools through the three guarded waterfall stages.
public struct ToolRuntime: Sendable {
    public typealias Waterfall = @Sendable (
        EventKey<ToolExecutionContext, WaterfallMode>,
        ToolExecutionContext
    ) async throws -> ToolExecutionContext

    public let registry: ToolRegistry
    private let waterfall: Waterfall

    public init(registry: ToolRegistry, waterfall: @escaping Waterfall) {
        self.registry = registry
        self.waterfall = waterfall
    }

    public func execute(name: ToolName, payload: String) async throws -> String {
        var context = ToolExecutionContext(name: name, payload: payload)
        context = try await waterfall(ToolEventKeys.preExecute, context)
        context = try await waterfall(ToolEventKeys.execute, context)
        context = try await waterfall(ToolEventKeys.postExecute, context)
        guard let result = context.result else {
            throw ToolRuntimeError.missingExecutionResult(name)
        }
        return result
    }
}

public enum ToolServiceKeys {
    public static let tools = ServiceKey<ToolRuntime>(label: "wiki.tools")
}

public enum ToolEventKeys {
    public static let preExecute = EventKey<ToolExecutionContext, WaterfallMode>(
        label: "tools/pre-execute")
    public static let execute = EventKey<ToolExecutionContext, WaterfallMode>(
        label: "tools/execute")
    public static let postExecute = EventKey<ToolExecutionContext, WaterfallMode>(
        label: "tools/post-execute")
}

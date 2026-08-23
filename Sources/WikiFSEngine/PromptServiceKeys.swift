import Cordis
import Foundation

/// Stable identity for one system-prompt section contribution.
public struct PromptSectionID: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

/// One ordered section of the assembled system prompt.
public struct PromptSection: Hashable, Sendable {
    public let id: PromptSectionID
    public let order: Int
    public let content: String

    public init(id: PromptSectionID, order: Int, content: String) {
        self.id = id
        self.order = order
        self.content = content
    }
}

public enum SystemPromptError: Error, Equatable, Sendable {
    case duplicateSection(PromptSectionID)
}

/// A reversible, token-owned system-prompt section registration.
public struct PromptSectionRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

/// Process-scoped system-prompt assembly seam.
///
/// Sections sort by explicit order and then stable id. Registrations are
/// token-owned so a stale disposer cannot remove a later replacement.
public actor SystemPromptService {
    private struct Registration: Sendable {
        let token: UUID
        let section: PromptSection
    }

    private var registrations: [PromptSectionID: Registration] = [:]

    public init() {}

    public func register(_ section: PromptSection) throws -> PromptSectionRegistration {
        guard registrations[section.id] == nil else {
            throw SystemPromptError.duplicateSection(section.id)
        }
        let token = UUID()
        registrations[section.id] = Registration(token: token, section: section)
        return PromptSectionRegistration { [weak self] in
            await self?.remove(id: section.id, token: token)
        }
    }

    public func sections() -> [PromptSection] {
        registrations.values.map(\.section).sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    public func assemble() -> String {
        sections()
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func remove(id: PromptSectionID, token: UUID) {
        guard registrations[id]?.token == token else { return }
        registrations.removeValue(forKey: id)
    }
}

/// Stable Cordis identity for system-prompt assembly.
public enum PromptServiceKeys {
    public static let systemPrompt = ServiceKey<SystemPromptService>(label: "wiki.system-prompt")
}

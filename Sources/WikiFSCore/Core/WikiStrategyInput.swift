import Foundation

/// Normalized editor input ready to persist: the write boundary's one
/// translation from raw editor text to stored columns. Produced by
/// `WikiStrategy.validatedInput(name:instructions:)`.
public struct WikiStrategyInput: Equatable, Sendable {
    /// Trimmed display name (empty is allowed).
    public let name: String

    /// The Markdown instructions, verbatim. `nil` means the editor's document
    /// was whitespace-only — the save resets the wiki to the Default strategy.
    public let instructions: String?

    public init(name: String, instructions: String?) {
        self.name = name
        self.instructions = instructions
    }
}

/// Rejection of oversized strategy text at the write boundary. Visible to the
/// caller (the editor surfaces it); nothing is truncated.
public enum WikiStrategyTextError: Error, Equatable, CustomStringConvertible {
    /// The trimmed name exceeds `WikiStrategy.nameCharacterLimit` characters.
    case nameTooLong(characterCount: Int, limit: Int)
    /// The instructions exceed `WikiStrategy.instructionsUTF8ByteLimit` UTF-8 bytes.
    case instructionsTooLarge(byteCount: Int, limit: Int)

    public var description: String {
        switch self {
        case let .nameTooLong(characterCount, limit):
            return "Strategy name is \(characterCount) characters; the limit is \(limit)."
        case let .instructionsTooLarge(byteCount, limit):
            return "Strategy instructions are \(byteCount) UTF-8 bytes; the limit is \(limit)."
        }
    }
}

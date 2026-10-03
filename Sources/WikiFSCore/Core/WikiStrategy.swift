import Foundation

/// The per-wiki editorial strategy document — the wiki-specific instructions
/// that control taxonomy, organization, and interpretation for future runs.
///
/// A `nil` strategy (`WikiStore.getWikiStrategy()` returning `nil`) is the
/// **Default** strategy: absence is the representation, not a sentinel name or
/// a special page. The Default strategy adds no strategy section to captured
/// state, so existing snapshots stay byte-identical.
///
/// The value is a copied `Sendable` snapshot of the committed row; callers
/// never hold a live handle into the store. `revision` and `updatedAt` are the
/// row's committed values at read time.
public struct WikiStrategy: Equatable, Sendable, Codable {
    /// Maximum stored name length, in Characters (grapheme clusters), counted
    /// after trimming surrounding whitespace. Named so the editor, the store's
    /// write boundary, and tests cite one constant.
    public static let nameCharacterLimit = 120

    /// Maximum stored instructions size, in UTF-8 bytes. Named so the editor,
    /// the store's write boundary, and tests cite one constant. Oversized
    /// input is rejected visibly — instructions are never silently truncated.
    public static let instructionsUTF8ByteLimit = 32 * 1024

    /// The editable display name, stored trimmed (may be empty).
    public let name: String

    /// The Markdown instructions, stored verbatim (surrounding whitespace is
    /// preserved — only a wholly whitespace-only document resets to Default).
    public let instructions: String

    /// The committed revision this snapshot was read at.
    public let revision: WikiStrategyRevision

    /// When this revision committed.
    public let updatedAt: Date

    public init(
        name: String,
        instructions: String,
        revision: WikiStrategyRevision,
        updatedAt: Date
    ) {
        self.name = name
        self.instructions = instructions
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

extension WikiStrategy {
    /// Validate and normalize editor input at the write boundary. This is the
    /// single translation both the store's save and the editor's preflight
    /// use, so the limits and the whitespace-reset rule cannot drift apart.
    ///
    /// - The name is trimmed; its Character count is then checked against
    ///   `nameCharacterLimit`.
    /// - The instructions' UTF-8 byte count is checked against
    ///   `instructionsUTF8ByteLimit` **before** the whitespace-reset rule, so
    ///   an oversized document is rejected visibly even when it is also
    ///   whitespace-only.
    /// - Whitespace-only instructions normalize to `nil` — the save resets
    ///   the wiki to the Default strategy.
    ///
    /// Throws `WikiStrategyTextError`; never truncates.
    public static func validatedInput(
        name: String,
        instructions: String
    ) throws -> WikiStrategyInput {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count <= nameCharacterLimit else {
            throw WikiStrategyTextError.nameTooLong(
                characterCount: trimmedName.count, limit: nameCharacterLimit)
        }
        let byteCount = instructions.utf8.count
        guard byteCount <= instructionsUTF8ByteLimit else {
            throw WikiStrategyTextError.instructionsTooLarge(
                byteCount: byteCount, limit: instructionsUTF8ByteLimit)
        }
        let normalizedInstructions =
            instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : instructions
        return WikiStrategyInput(name: trimmedName, instructions: normalizedInstructions)
    }
}

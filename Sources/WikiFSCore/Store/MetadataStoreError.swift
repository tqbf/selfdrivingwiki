import Foundation

/// A persisted metadata row violated an invariant that the Swift type system
/// normally makes unrepresentable. Callers must surface this rather than
/// silently guessing at corrupted role, counter, or decimal data.
public enum MetadataStoreError: Error, Equatable, Sendable {
    case unknownPageVersionSourceRole(String)
    case malformedDecimal(String)
    case counterOverflow
    case invalidUsageValue(field: String)
    case staleChatTurnClaim
    case nonActiveChatTurnState(ChatTurnPersistenceState)
}

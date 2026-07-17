import Foundation

/// Sort criteria for the sidebar page list.
/// `rawValue` matches the case name so the enum is trivially `Codable`
/// should we later persist the preference.
public enum PageSortOrder: String, CaseIterable, Sendable {
    /// Most recently edited first (`updated_at DESC`).
    case lastUpdated
    /// Most recently created first (`created_at DESC`).
    case newestFirst
    /// Case-insensitive alphabetical (`title COLLATE NOCASE ASC`).
    case titleAZ
}

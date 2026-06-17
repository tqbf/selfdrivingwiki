import Foundation

public enum WikiManagerError: Error, Equatable, CustomStringConvertible {
    case emptyDisplayName
    case exportWouldOverwriteSource
    case sqlite(String)
    case unknownWiki(String)

    public var description: String {
        switch self {
        case .emptyDisplayName:
            return "Wiki name cannot be empty."
        case .exportWouldOverwriteSource:
            return "Choose a backup location outside the wiki's backing database file."
        case .sqlite(let message):
            return "SQLite checkpoint failed: \(message)"
        case .unknownWiki(let id):
            return "No wiki exists with id \(id)."
        }
    }
}

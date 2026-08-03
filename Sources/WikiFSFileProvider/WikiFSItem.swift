#if os(macOS)  // File Provider extension — macOS-only (FileProvider framework)
import FileProvider
import UniformTypeIdentifiers

/// Read-only `NSFileProviderItem` backed by a resolved `ProjectedNode`.
/// Everything the system needs to show a file/folder in the projection and
/// decide when to re-fetch content. Static-but-correct versions so the FIRST
/// read materializes the right bytes (dynamic change-signaling is Phase 3).
final class WikiFSItem: NSObject, NSFileProviderItem {
    private let node: ProjectedNode

    init(node: ProjectedNode) {
        self.node = node
    }

    var itemIdentifier: NSFileProviderItemIdentifier { node.id }
    var parentItemIdentifier: NSFileProviderItemIdentifier { node.parent }
    var filename: String { node.name }

    var contentType: UTType {
        if node.isFolder { return .folder }
        // Ingested files (sources): content-derived MIME first, then the original
        // dropped extension, falling back to `.data` (generic binary) for
        // unknown/empty. This is a dedicated branch that runs ONLY for
        // ingested-file leaves; the page (.md) and index (.json/.jsonl) logic
        // below is unchanged so those types do not regress.
        if node.ingestedExt != nil {
            if let mime = node.mimeType, let type = UTType(mimeType: mime) { return type }
            if let ext = node.ingestedExt, !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type }
            return .data
        }
        if node.name.hasSuffix(".md") { return UTType(filenameExtension: "md") ?? .plainText }
        // manifest.json → public.json; the .jsonl indexes are line-delimited
        // JSON with no registered UTI, so present them as plain text (an agent
        // reads them with `cat`, not a typed loader).
        if node.name.hasSuffix(".json") { return .json }
        if node.name.hasSuffix(".jsonl") { return .plainText }
        return .plainText
    }

    // Read-only: folders can be enumerated, files can be read. Nothing else.
    var capabilities: NSFileProviderItemCapabilities {
        node.isFolder ? [.allowsReading, .allowsContentEnumerating] : .allowsReading
    }

    // NEVER nil for files — a wrong/absent size truncates `cat`.
    var documentSize: NSNumber? { node.isFolder ? nil : NSNumber(value: node.size) }

    var creationDate: Date? { node.created }
    var contentModificationDate: Date? { node.modified }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: node.contentVersion,
                                  metadataVersion: node.metadataVersion)
    }
}
#endif  // os(macOS)


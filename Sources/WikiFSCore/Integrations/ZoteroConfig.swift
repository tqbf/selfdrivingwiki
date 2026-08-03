import Foundation

/// Non-secret Zotero settings — library ID and an optional override of the local
/// Zotero data directory. The API key itself is NOT here: secrets go in Keychain
/// via `ZoteroCredentialStore`, never in a plaintext JSON file.
///
/// App-wide, not per-wiki: a Zotero account is a property of the person using the
/// app, not of any one wiki — one library, many wikis is the common case, so this
/// is persisted once at the App Group container root, a sibling of `wikis.json`
/// rather than a field on `WikiDescriptor`. Follows `WikiRegistry`'s load/save
/// pattern exactly (pure value type, explicit injected directory, atomic write).
public struct ZoteroConfig: JSONSidecarConfig {
    /// The numeric Zotero user library ID. `nil` until the user configures it.
    public var libraryID: String?

    /// Overrides `ZoteroLocalStorage.defaultDirectory()` (`~/Zotero`). `nil` means
    /// use the default.
    public var zoteroDirOverride: String?

    public init(libraryID: String? = nil, zoteroDirOverride: String? = nil) {
        self.libraryID = libraryID
        self.zoteroDirOverride = zoteroDirOverride
    }

    /// The config's JSON filename inside the App Group container.
    public static let fileName = "zotero-config.json"

    public var isConfigured: Bool {
        guard let libraryID else { return false }
        return !libraryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The directory to look for `storage/<key>/<filename>` under: the override
    /// when set, else the default `~/Zotero`.
    public func zoteroDirectory() -> URL {
        if let override = zoteroDirOverride, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return ZoteroLocalStorage.defaultDirectory()
    }

    // MARK: - Persistence (via `JSONSidecarConfig`)

    /// Load from `zotero-config.json` in `directory`. A missing or corrupt file
    /// degrades to an empty (unconfigured) config rather than throwing — same
    /// fresh-install behavior as `WikiRegistry.load`. Delegates the file read +
    /// decode to `JSONSidecarConfig.load(from:)` and supplies the empty default.
    public static func load(from directory: URL) -> ZoteroConfig {
        load(from: directory) ?? ZoteroConfig()
    }
}

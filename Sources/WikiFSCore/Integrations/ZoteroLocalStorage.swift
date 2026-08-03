import Foundation

/// Resolves a Zotero attachment to its local file on disk, without ever touching
/// the network.
///
/// Why this is safe: Zotero's own sync client (read from its open-source GitHub
/// repo, `chrome/content/zotero/xpcom/storage/{zfs,storageLocal}.js`) downloads an
/// attachment fully to a temp file, then commits it with a single atomic
/// `OS.File.move` into `storage/<key>/<filename>` for the common single-file case
/// (a plain PDF or Markdown attachment, as opposed to a multi-file web-snapshot
/// ZIP, which extracts entry-by-entry with no such guarantee — out of scope here).
/// A reader therefore only ever sees the fully-old or fully-new file, never a torn
/// write — confirmed against the user's live library, two different attachment
/// keys, both `imported_file` and `imported_url` link modes.
///
/// `linked_file`/`linked_url` attachments point elsewhere on disk or have no local
/// copy at all (`ZoteroAttachment.hasLocalCopy == false`) — v1 has no network
/// download fallback for those; `resolve` reports them `.unavailable`.
public enum ZoteroLocalStorage {

    /// `~/Zotero` — the Zotero desktop client's default data directory. NOT read
    /// from the `ZOTERO_DIR` environment variable (the convention used by the
    /// user's companion `zotero-extraction` Python tool): this is a GUI app, and
    /// its behavior shouldn't depend on how it happened to be launched. An
    /// override lives in `ZoteroConfig.zoteroDirOverride` instead.
    public static func defaultDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Zotero", isDirectory: true)
    }

    /// The expected local path for an `imported_file`/`imported_url` attachment:
    /// `<zoteroDir>/storage/<key>/<filename>`. Pure string/path composition — no
    /// I/O, no existence check.
    public static func localPath(zoteroDir: URL, key: String, filename: String) -> URL {
        zoteroDir
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// Where an attachment's bytes should come from.
    public enum AttachmentSource: Equatable, Sendable {
        case local(URL)
        /// No network fallback in v1 — `reason` is a user-readable explanation
        /// (e.g. "not synced locally yet" or "Zotero doesn't keep a local copy of
        /// linked attachments").
        case unavailable(reason: String)
    }

    /// Pure resolution: given the attachment + a Zotero data directory + an
    /// injected existence check (so tests never touch the real filesystem),
    /// decide where the bytes come from. Mirrors `PathPreflight.resolve`'s
    /// injection shape.
    public static func resolve(
        _ attachment: ZoteroAttachment,
        zoteroDir: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> AttachmentSource {
        guard attachment.hasLocalCopy else {
            return .unavailable(reason: "Zotero doesn't keep a local copy of linked attachments.")
        }
        guard let filename = attachment.filename, !filename.isEmpty else {
            return .unavailable(reason: "This attachment has no filename to look up.")
        }
        let path = localPath(zoteroDir: zoteroDir, key: attachment.key, filename: filename)
        guard fileExists(path) else {
            return .unavailable(reason: "Not synced to this Mac yet — sync in Zotero first.")
        }
        return .local(path)
    }
}

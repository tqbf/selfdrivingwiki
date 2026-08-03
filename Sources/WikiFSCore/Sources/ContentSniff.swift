import Foundation

/// Pure, dependency-free content-type detection from magic bytes (the leading
/// bytes of a data blob). Extracted from `URLFetchService` so the store,
/// ingest paths, and any future caller can sniff without depending on the
/// URL-fetch layer.
///
/// Kept deliberately small: each magic-number check copies at most 8 bytes.
/// Extend the table as needed (Office docs, EPUB, etc.).
public enum ContentSniff {

    /// Content-derived MIME type from leading magic-number bytes, or `nil` if
    /// the bytes don't match any known binary signature. Cheap prefix check
    /// only — this is NOT a full content inspector.
    public static func mimeType(of data: Data) -> String? {
        let head = Array(data.prefix(8))
        func starts(with magic: [UInt8]) -> Bool {
            guard head.count >= magic.count else { return false }
            return Array(head.prefix(magic.count)) == magic
        }

        if starts(with: Array("%PDF".utf8)) { return "application/pdf" }
        if starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }  // \x89PNG
        if starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "application/zip" }  // PK\x03\x04
        return nil
    }
}

import Foundation

/// Non-secret Zotero settings — the numeric library ID and the attachment
/// keys to acquire. The API key itself is NOT here: secrets go in Keychain
/// via `KeychainCredentialService` (the `.zoteroAPIKey()` reference), never in a
/// plaintext JSON file.
///
/// App-wide, not per-wiki: a Zotero account is a property of the person using
/// the app, not of any one wiki — one library, many wikis is the common case,
/// so this is persisted once at the App Group container root, a sibling of
/// `wikis.json` rather than a field on `WikiDescriptor`. Follows
/// `WikiRegistry`'s load/save pattern exactly (pure value type, explicit
/// injected directory, atomic write).
///
/// `attachments` lists Zotero ATTACHMENT keys (8-character uppercase
/// alphanumeric item keys). Each key acquires one byteless source via
/// `wikictl extractor sync zotero`; the reviewed Zotero package downloads the file and
/// its item metadata. The retired `zoteroDirOverride` local-storage key is
/// no longer written and no longer read for acquisition — decode stays
/// tolerant of old files that still carry it.
public struct ZoteroConfig: JSONSidecarConfig {
    /// The numeric Zotero user library ID. `nil` until the user configures it.
    public var libraryID: String?

    /// Retired: the local Zotero data-directory override. Nothing reads it
    /// for acquisition anymore; the field survives decode-tolerant so old
    /// `zotero-config.json` files still load, and it is never written.
    public var zoteroDirOverride: String?

    /// The Zotero attachment keys to acquire, in configured order.
    public var attachments: [String]

    public init(
        libraryID: String? = nil,
        zoteroDirOverride: String? = nil,
        attachments: [String] = []
    ) {
        self.libraryID = libraryID
        self.zoteroDirOverride = zoteroDirOverride
        self.attachments = attachments
    }

    /// The config's JSON filename inside the App Group container.
    public static let fileName = "zotero-config.json"

    /// `true` when a non-blank library ID is set. Attachment keys are
    /// validated separately (`Self.validatedAttachments`) so a configured
    /// library with malformed keys fails the sync loudly instead of silently.
    public var isConfigured: Bool {
        guard let libraryID else { return false }
        return !libraryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Attachment-key validation

    /// Zotero item keys are 8 characters from this uppercase alphabet.
    public static let attachmentKeyAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    /// Validates one attachment key: exactly 8 characters from the Zotero
    /// key alphabet. Returns a caller-facing failure message on rejection.
    public static func attachmentKeyInvalidReason(_ key: String) -> String? {
        guard key.count == 8 else {
            return "attachment key \(key) must be exactly 8 characters"
        }
        guard key.allSatisfy({ attachmentKeyAlphabet.contains($0) }) else {
            return "attachment key \(key) may only use uppercase A–Z and 0–9"
        }
        return nil
    }

    /// The validated attachment keys, preserving order, rejecting malformed
    /// entries and duplicates. Callers save the validated list, so a typo
    /// fails at save time instead of at sync time.
    public static func validatedAttachments(_ rawKeys: [String]) throws -> [String] {
        var seen = Set<String>()
        var validated: [String] = []
        for key in rawKeys {
            if let reason = attachmentKeyInvalidReason(key) {
                throw ZoteroConfigError.invalidAttachmentKey(reason)
            }
            guard seen.insert(key).inserted else {
                throw ZoteroConfigError.duplicateAttachmentKey(key)
            }
            validated.append(key)
        }
        return validated
    }

    // MARK: - Persistence (via `JSONSidecarConfig`)

    /// Load from `zotero-config.json` in `directory`. A missing or corrupt file
    /// degrades to an empty (unconfigured) config rather than throwing — same
    /// fresh-install behavior as `WikiRegistry.load`. Delegates the file read +
    /// decode to `JSONSidecarConfig.load(from:)` and supplies the empty default.
    public static func load(from directory: URL) -> ZoteroConfig {
        load(from: directory) ?? ZoteroConfig()
    }

    // MARK: - Codable (custom so the retired key is never written)

    private enum CodingKeys: String, CodingKey {
        case libraryID, zoteroDirOverride, attachments
    }

    /// Encoding writes `libraryID` and `attachments` only. The retired
    /// `zoteroDirOverride` key is never written again (no local reads exist);
    /// decoding still accepts it so old files load unchanged.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(libraryID, forKey: .libraryID)
        try container.encode(attachments, forKey: .attachments)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        zoteroDirOverride = try container.decodeIfPresent(String.self, forKey: .zoteroDirOverride)
        attachments = try container.decodeIfPresent([String].self, forKey: .attachments) ?? []
    }
}

/// Typed Zotero configuration failures with caller-facing messages.
public enum ZoteroConfigError: Error, Equatable, LocalizedError {
    case invalidAttachmentKey(String)
    case duplicateAttachmentKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAttachmentKey(let reason):
            return reason
        case .duplicateAttachmentKey(let key):
            return "attachment key \(key) is listed more than once"
        }
    }
}

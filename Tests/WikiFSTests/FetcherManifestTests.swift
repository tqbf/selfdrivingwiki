import Foundation
import Testing
import WikiFSTypes

/// AC.1 — the manifest layer admits and rejects the fetcher role.
///
/// The fetcher role is a manifest-revision-4 feature that rides on protocol
/// revision 5 and the `network` capability. These tests pin the admission
/// rules (decode + in-memory construction) and the canonical-encoding
/// guarantee: revision-3 canonical bytes (and therefore package digests)
/// are unchanged by the revision-4 code path.
@Suite("Fetcher manifest admission and canonical encoding")
struct FetcherManifestTests {

    // MARK: - Fixtures

    /// One parameterized manifest document. Defaults describe a VALID
    /// revision-4 fetcher registration claiming `application/zotero`.
    private static func manifestJSON(
        manifestRevision: Int = 4,
        protocolRevision: Int = 5,
        role: String? = "fetcher",
        kinds: String = "[]",
        mimeTypes: String = "[\"application/zotero\"]",
        filenameExtensions: String = "[]",
        capabilities: String = "[\"network\"]",
        includeKindsKey: Bool = true,
        sync: String? = nil
    ) -> String {
        var registration = """
                    {
                      "id": "attachment",
                      "displayName": "Zotero Attachment",
                      \(includeKindsKey ? "\"kinds\": \(kinds)," : "")
                      "mimeTypes": \(mimeTypes),
                      "filenameExtensions": \(filenameExtensions)
        """
        if let role {
            registration += ",\n                      \"role\": \"\(role)\""
        }
        if let sync {
            registration += ",\n                      \"sync\": \(sync)"
        }
        registration += "\n                    }"
        return """
        {
          "manifestRevision": \(manifestRevision),
          "packageID": "org.selfdrivingwiki.zotero",
          "version": "1.0.0",
          "displayName": "Zotero Attachment",
          "protocolRevision": \(protocolRevision),
          "entryPoint": "bin/zotero-extractor",
          "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
          "registrations": [
        \(registration)
          ],
          "capabilities": \(capabilities),
          "files": [
            {
              "path": "bin/zotero-extractor",
              "digest": "0000000000000000000000000000000000000000000000000000000000000000"
            }
          ],
          "limits": {
            "maximumInputByteCount": 1048576,
            "maximumMarkdownOutputByteCount": 134217728,
            "maximumDurationMilliseconds": 600000,
            "maximumProgressEventCount": 64
          }
        }
        """
    }

    /// A valid revision-3 sync declaration targeting the claimed MIME.
    private static let admittedSync = """
    {
      "configFileName": "zotero-config.json",
      "urlTemplate": "https://api.zotero.org/users/{userID}/items/{itemKey}/file",
      "fields": [
        {"name": "userID", "required": true},
        {"name": "itemKeys", "required": true, "isList": true}
      ],
      "sourceMIMEType": "application/zotero"
    }
    """

    private static func decode(_ json: String) throws -> ExtractorManifest {
        try JSONDecoder().decode(ExtractorManifest.self, from: Data(json.utf8))
    }

    // MARK: - Admission

    @Test func validFetcherRegistrationAdmits() throws {
        let manifest = try Self.decode(Self.manifestJSON())
        #expect(manifest.manifestRevision.rawValue == 4)
        #expect(manifest.protocolRevision == .v5)
        let registration = try #require(manifest.registrations.first)
        #expect(registration.role == .fetcher)
        #expect(registration.kinds.isEmpty)
        #expect(registration.filenameExtensions.isEmpty)
        #expect(registration.mimeTypes.map(\.rawValue) == [ContentTypeRegistry.zoteroAttachment])
    }

    @Test func fetcherSyncWithClaimedSourceMIMEAdmits() throws {
        let manifest = try Self.decode(Self.manifestJSON(sync: Self.admittedSync))
        let registration = try #require(manifest.registrations.first)
        #expect(registration.role == .fetcher)
        #expect(registration.sync?.sourceMIMEType?.rawValue == ContentTypeRegistry.zoteroAttachment)
    }

    // MARK: - Rejection

    @Test func roleKeyOnRevision3ManifestRejected() {
        #expect(throws: (any Error).self) {
            // The revision-3 key policy rejects the unknown `role` field
            // before any fetcher rule applies.
            _ = try Self.decode(Self.manifestJSON(manifestRevision: 3, kinds: "[\"pdf\"]"))
        }
    }

    @Test func fetcherWithOperationKindsRejected() {
        #expect(throws: (any Error).self) {
            _ = try Self.decode(Self.manifestJSON(kinds: "[\"pdf\"]"))
        }
    }

    @Test func fetcherWithFilenameExtensionsRejected() {
        #expect(throws: (any Error).self) {
            _ = try Self.decode(Self.manifestJSON(filenameExtensions: "[\"zotero\"]"))
        }
    }

    @Test func fetcherWithProtocolRevisionFourRejected() {
        #expect(throws: (any Error).self) {
            _ = try Self.decode(Self.manifestJSON(protocolRevision: 4))
        }
    }

    @Test func fetcherWithoutNetworkCapabilityRejected() {
        #expect(throws: (any Error).self) {
            _ = try Self.decode(Self.manifestJSON(capabilities: "[]"))
        }
    }

    @Test func syncWithUnclaimedSourceMIMERejected() {
        let unclaimedSync = """
        {
          "configFileName": "zotero-config.json",
          "urlTemplate": "https://api.zotero.org/users/{userID}/items/{itemKey}/file",
          "fields": [
            {"name": "userID", "required": true},
            {"name": "itemKeys", "required": true, "isList": true}
          ],
          "sourceMIMEType": "application/x-other"
        }
        """
        #expect(throws: (any Error).self) {
            _ = try Self.decode(Self.manifestJSON(sync: unclaimedSync))
        }
    }

    @Test func fetcherWithEmptyMIMETypesRejected() {
        #expect(throws: (any Error).self) {
            _ = try Self.decode(Self.manifestJSON(mimeTypes: "[]"))
        }
    }

    // MARK: - Canonical encoding

    @Test func revision4CanonicalJSONAlwaysCarriesRole() throws {
        // A revision-4 FETCHER manifest…
        let fetcherManifest = try Self.decode(Self.manifestJSON())
        let fetcherJSON = String(decoding: try fetcherManifest.canonicalJSON(), as: UTF8.self)
        #expect(fetcherJSON.contains("\"role\""))

        // …and a revision-4 plain-EXTRACTOR manifest both write `role`.
        let extractorManifest = try Self.decode(Self.manifestJSON(
            role: "extractor",
            kinds: "[\"pdf\"]",
            mimeTypes: "[\"application/pdf\"]"))
        #expect(extractorManifest.registrations.first?.role == .extractor)
        let extractorJSON = String(decoding: try extractorManifest.canonicalJSON(), as: UTF8.self)
        #expect(extractorJSON.contains("\"role\""))
    }

    @Test func revision3CanonicalJSONNeverCarriesRole() throws {
        let manifest = try Self.decode(Self.manifestJSON(
            manifestRevision: 3,
            role: nil,
            kinds: "[\"pdf\"]",
            mimeTypes: "[\"application/pdf\"]"))
        #expect(manifest.manifestRevision.rawValue == 3)
        let canonical = String(decoding: try manifest.canonicalJSON(), as: UTF8.self)
        #expect(canonical.contains("\"role\"") == false)
    }

    @Test func revision3DigestStableAcrossEquivalentFixtures() throws {
        let json = Self.manifestJSON(
            manifestRevision: 3,
            role: nil,
            kinds: "[\"pdf\"]",
            mimeTypes: "[\"application/pdf\"]")

        // The same document decoded twice yields the same canonical bytes
        // and the same package digest.
        let first = try Self.decode(json)
        let second = try Self.decode(json)
        #expect(try first.canonicalJSON() == second.canonicalJSON())
        #expect(try first.packageDigest() == second.packageDigest())

        // An equivalent revision-3 manifest constructed in memory (the
        // same registration values through the validating initializer)
        // produces the SAME digest: adding the revision-4 role path did
        // not alter revision-3 canonical bytes.
        let equivalent = try ExtractorManifest(
            manifestRevision: first.manifestRevision,
            packageID: first.packageID,
            version: first.version,
            displayName: first.displayName,
            protocolRevision: first.protocolRevision,
            entryPoint: first.entryPoint,
            launch: first.launch,
            registrations: first.registrations,
            capabilities: first.capabilities,
            files: first.files,
            limits: first.limits)
        #expect(try equivalent.packageDigest() == first.packageDigest())
    }

    @Test func revision4RegistrationWithoutRoleDecodesAsExtractor() throws {
        // Revision 4 makes `kinds` optional and defaults a missing `role`
        // to `extractor` — the older canonical shape stays readable.
        let manifest = try Self.decode(Self.manifestJSON(
            role: nil,
            kinds: "[\"pdf\"]",
            mimeTypes: "[\"application/pdf\"]"))
        #expect(manifest.manifestRevision.rawValue == 4)
        #expect(manifest.registrations.first?.role == .extractor)
        #expect(manifest.registrations.first?.kinds == [.pdf])
    }

    @Test func revision4FetcherMayOmitKindsKeyEntirely() throws {
        let manifest = try Self.decode(Self.manifestJSON(includeKindsKey: false))
        let registration = try #require(manifest.registrations.first)
        #expect(registration.role == .fetcher)
        #expect(registration.kinds.isEmpty)
    }
}

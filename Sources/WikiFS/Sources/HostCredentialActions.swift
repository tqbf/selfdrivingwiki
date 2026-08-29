import Foundation
import WikiFSCore

/// Host-owned privileged credential actions for Settings (issue #1159,
/// plans/credential-service.md). A Settings VIEW may request an operation by
/// typed reference, but the value resolution happens HERE — outside the view
/// — and only a redacted outcome (nil = success, message = failure) crosses
/// back into SwiftUI. `CredentialSettingsHostedTests` enforces that the view
/// files contain no value-returning credential calls; these actions are the
/// sanctioned seam.
enum HostCredentialActions {

    /// Verify the stored Zotero API key against the Zotero API. Resolves
    /// `.zoteroAPIKey()` in the privileged layer and returns only a redacted
    /// outcome.
    static func verifyZotero(
        fetcher: any ZoteroClient.RequestFetcher
    ) -> @Sendable (_ libraryID: String) async -> String? {
        { libraryID in
            let credentials = KeychainCredentialService()
            do {
                let resolved = try credentials.resolve(.zoteroAPIKey())
                let config = ZoteroClient.Config(
                    libraryID: libraryID, apiKey: resolved.value)
                let client = ZoteroClient(config: config, fetcher: fetcher)
                try await client.verifyConnection()
                return nil
            } catch CredentialStoreError.notConfigured {
                return "No API key is stored. Save a key first."
            } catch {
                return (error as? ZoteroClient.ZoteroError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Verify Docling Serve connectivity with the STORED token (resolved in
    /// the privileged layer; never handed to the caller). Absent token → an
    /// anonymous probe, matching the optional-token server mode.
    static func verifyDocling(
        fetcher: any HTTPRequestFetcher
    ) -> @Sendable (_ endpoint: String) async -> String? {
        { endpoint in
            let credentials = KeychainCredentialService()
            let token: String
            do {
                guard let reference = CredentialReference.extraction(
                    ExtractionSecret.doclingServeToken)
                else { return "Could not read the stored token." }
                token = try credentials.resolve(reference).value
            } catch CredentialStoreError.notConfigured {
                token = ""
            } catch {
                return "Could not read the stored token."
            }
            let client = DoclingServeClient(
                endpoint: endpoint, apiToken: token, fetcher: fetcher)
            do {
                try await client.verifyConnection()
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

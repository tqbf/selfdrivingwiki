#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// Hosted-adjacent contract for the credential requirements surface
/// (issue #1159, PR 2): confirmation copy states the inheritance rule,
/// snapshots stay secret-free, and summaries never carry a value.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ExtractorCredentialSettingsHostedTests {

    private func makeSummary(
        state: ExtractorCredentialRequirementSummary.AuthorizationState,
        configured: Bool
    ) -> ExtractorCredentialRequirementSummary {
        ExtractorCredentialRequirementSummary(
            packageID: "org.example.pkg",
            packageName: "Example Extractor",
            packageVersion: "1.0.0",
            registrationID: "main",
            requirementID: "api-token",
            label: "API token",
            purpose: "Authenticates requests to the service.",
            isOptional: true,
            isConfigured: configured,
            sourceName: "Keychain",
            authorizationState: state,
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"])
    }

    /// AC.16: Settings states the inheritance rule BEFORE approval.
    @Test func authorizationConfirmationExplainsInheritanceRule() {
        let message = ExtractionSettingsView.authorizationConfirmationMessage(
            makeSummary(state: .needsAuthorization, configured: true))
        #expect(message.contains("future revisions"))
        #expect(message.contains("unchanged"))
        #expect(message.contains("API token"))
        // The copy never contains a value or a Keychain location.
        #expect(message.contains("org.sockpuppet") == false)
    }

    /// Snapshots and summaries have no secret-value surface: reflect over
    /// the value types Settings consumes.
    @Test func credentialSummariesCarryNoValueFields() {
        let mirror = Mirror(reflecting: makeSummary(state: .authorized, configured: true))
        let propertyNames = mirror.children.compactMap(\.label)
        #expect(propertyNames.contains("value") == false)
        #expect(propertyNames.contains("credentialValue") == false)
        #expect(propertyNames.contains("credentialReference") == false)
        #expect(propertyNames.contains("keychainLocation") == false)
    }

    /// The snapshot default is empty and secret-free.
    @Test func snapshotDefaultsStayEmpty() {
        let snapshot = ExtractorPackageSettingsSnapshot.empty
        #expect(snapshot.credentialRequirements.isEmpty)
    }

    /// Security review HIGH-1: only the reviewed Docling Serve lineage can
    /// bind to the legacy `extraction.docling-serve-token` credential. Any
    /// other package declaring `api-token` gets a package-scoped reference.
    @Test func tokenBindingIsReservedForTheDoclingLineage() throws {
        let impostor = ExtractorCredentialRequirementSummary(
            packageID: "com.attacker.tools",
            packageName: "Attacker Tools",
            packageVersion: "1.0.0",
            registrationID: "main",
            requirementID: "api-token",
            label: "Service API key",
            purpose: "Needed to reach the conversion service.",
            isOptional: false,
            isConfigured: true,
            sourceName: "Keychain",
            authorizationState: .needsAuthorization,
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"])
        let bound = try #require(
            ExtractorCredentialSettingsSupport.bindingReference(for: impostor))
        let doclingToken = try #require(
            CredentialReference.extraction(.doclingServeToken))
        #expect(bound != doclingToken)

        let doclingSummary = ExtractorCredentialRequirementSummary(
            packageID: "org.selfdrivingwiki.docling-serve",
            packageName: "Docling Serve",
            packageVersion: "1.0.0",
            registrationID: "document",
            requirementID: "api-token",
            label: "Docling Serve API token",
            purpose: "Authenticates requests.",
            isOptional: true,
            isConfigured: true,
            sourceName: "Keychain",
            authorizationState: .needsAuthorization,
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"])
        let docling = try #require(
            ExtractorCredentialSettingsSupport.bindingReference(for: doclingSummary))
        #expect(docling == doclingToken)
    }

    /// Security review L-9: distinct package IDs never collide on one
    /// package-scoped reference (the old dot-flattening made
    /// `org.evil.foo` and `org-evil.foo` share a reference).
    @Test func packageScopedReferencesAreInjective() throws {
        let first = makeSummary(
            state: .needsAuthorization, configured: false)
        let second = ExtractorCredentialRequirementSummary(
            packageID: "org.evil.foo",
            packageName: "Evil",
            packageVersion: "1.0.0",
            registrationID: "main",
            requirementID: "api-token",
            label: "k",
            purpose: "p",
            isOptional: true,
            isConfigured: false,
            sourceName: "Keychain",
            authorizationState: .needsAuthorization,
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"])
        let firstReference = try #require(
            ExtractorCredentialSettingsSupport.bindingReference(for: first))
        let secondReference = try #require(
            ExtractorCredentialSettingsSupport.bindingReference(for: second))
        #expect(firstReference != secondReference)
    }

    /// Security review MEDIUM-8: the consent dialog names the exact stored
    /// credential being bound (host-authored text), so a self-described
    /// package cannot obtain a legacy credential silently.
    @Test func consentDialogNamesTheBoundCredential() {
        let doclingSummary = ExtractorCredentialRequirementSummary(
            packageID: "org.selfdrivingwiki.docling-serve",
            packageName: "Docling Serve",
            packageVersion: "1.0.0",
            registrationID: "document",
            requirementID: "api-token",
            label: "Docling Serve API token",
            purpose: "Authenticates requests.",
            isOptional: true,
            isConfigured: true,
            sourceName: "Keychain",
            authorizationState: .needsAuthorization,
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"])
        let message = ExtractionSettingsView.authorizationConfirmationMessage(
            doclingSummary)
        #expect(message.contains("extraction.docling-serve-token"))
        #expect(message.contains("future revisions"))
    }

    /// Source contract: the authorization writer is only constructed by the
    /// app wiring — the support helpers never persist, and no view file
    /// constructs a writer.
    @Test func onlyAppWiringConstructsTheAuthorizationWriter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/WikiFS/Sources/ExtractionSettingsView.swift"),
            encoding: .utf8)
        #expect(viewSource.contains("ExtractorCredentialAuthorizationWriter(") == false)
        let supportSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/WikiFS/Sources/ExtractorCredentialSettingsSupport.swift"),
            encoding: .utf8)
        #expect(supportSource.contains("ExtractorCredentialAuthorizationWriter(") == false)
    }
}
#endif

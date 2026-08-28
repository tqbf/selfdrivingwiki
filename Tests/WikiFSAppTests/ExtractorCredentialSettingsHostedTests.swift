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

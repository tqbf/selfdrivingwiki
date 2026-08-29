import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// Grammar, namespace, factory, and Codable-stability tests for
/// `CredentialReference` (issue #1159 — AC.1: distinct typed namespaces with
/// validated construction).
struct CredentialReferenceTests {

    // MARK: Grammar

    @Test func acceptsWellFormedReferences() throws {
        for raw in ["acp.agent-api-key", "zotero.api-key",
                    "provider.claude-acp.anthropic-api-key",
                    "a.b", "vimeo.api-key", "provider.my_agent.OPENAI_API_KEY"] {
            #expect(try CredentialReference(validating: raw).rawValue == raw)
        }
    }

    @Test func rejectsMalformedReferences() {
        for raw in ["", "single", "a.b.c.d", ".leading", "trailing.",
                    "has space.key", "ok-key.≠nonascii",
                    "under_score..gap", "toolong." + String(repeating: "a", count: 70)] {
            #expect(throws: CredentialReferenceError.self) {
                _ = try CredentialReference(validating: raw)
            }
        }
    }

    @Test func uppercaseLettersAreGrammarValid() throws {
        // The grammar admits ASCII letters in any case (injective, and it
        // lets dynamic domains embed existing identifiers verbatim).
        #expect(try CredentialReference(validating: "UPPER.key").rawValue == "UPPER.key")
    }

    @Test func labelBoundaries() {
        #expect(CredentialReference.isValidLabel("a"))
        #expect(CredentialReference.isValidLabel(String(repeating: "a", count: 64)))
        #expect(!CredentialReference.isValidLabel(String(repeating: "a", count: 65)))
        #expect(CredentialReference.isValidLabel("a-b_c9"))
        #expect(!CredentialReference.isValidLabel("-leading"))
        #expect(!CredentialReference.isValidLabel("trailing-"))
        #expect(!CredentialReference.isValidLabel("_leading"))
        #expect(!CredentialReference.isValidLabel("9--"))  // ends with '-'
    }

    // MARK: Namespace separation (AC.1)

    @Test func namespacesRemainDistinct() throws {
        // Same final label in different domains are different credentials.
        let acp = try CredentialReference(validating: "acp.api-key")
        let zotero = try CredentialReference(validating: "zotero.api-key")
        #expect(acp != zotero)
        #expect(acp.hashValue != zotero.hashValue || acp != zotero)

        // Label count differences are distinct identities.
        let two = try CredentialReference(validating: "acp.provider")
        let three = try CredentialReference(validating: "acp.provider.claude")
        #expect(two != three)

        // Underscore vs hyphen are distinct labels (injective grammar).
        let hyphen = try CredentialReference(validating: "provider.my-agent.k")
        let underscore = try CredentialReference(validating: "provider.my_agent.k")
        #expect(hyphen != underscore)
    }

    // MARK: Typed factories

    @Test func legacyFactoriesProduceExpectedRawValues() {
        #expect(CredentialReference.acpAgent().rawValue == "acp.agent-api-key")
        #expect(CredentialReference.zoteroAPIKey().rawValue == "zotero.api-key")
        #expect(
            CredentialReference.acpProvider(ProviderID(rawValue: "claude-acp"))?
                .rawValue == "acp.provider.claude-acp")
        #expect(
            CredentialReference.extraction("docling-serve-token")?
                .rawValue == "extraction.docling-serve-token")
    }

    @Test func credentialFactoriesRejectUncheckedComponents() {
        // A provider id that cannot form a valid label yields nil — the
        // adapter keeps its legacy path for such ids instead of misfiling
        // the credential under a mangled name.
        #expect(CredentialReference.acpProvider(ProviderID(rawValue: "my agent")) == nil)
        #expect(CredentialReference.acpProvider(ProviderID(rawValue: "")) == nil)
        #expect(CredentialReference.acpProvider(ProviderID(rawValue: "a.b")) == nil)
        #expect(CredentialReference.extraction("not a key") == nil)
    }

    @Test func providerSecretFactoryIsDeterministic() throws {
        let variable = ProviderSecretEnvironmentVariable.anthropic
        let first = CredentialReference.providerSecret(
            providerID: ProviderID(rawValue: "claude-acp"), variable: variable)
        let second = CredentialReference.providerSecret(
            providerID: ProviderID(rawValue: "claude-acp"), variable: variable)
        #expect(first == second)
        #expect(first?.rawValue == "provider.claude-acp.anthropic-api-key")
        #expect(
            CredentialReference.providerSecret(
                providerID: ProviderID(rawValue: "gemini"),
                variable: .openAI)?.rawValue == "provider.gemini.openai-api-key")
        #expect(first?.domain == "provider")
    }

    // MARK: Codable stability + Comparable

    @Test func codableRoundTripsThroughTheRawString() throws {
        let original = try CredentialReference(validating: "provider.claude-acp.anthropic-api-key")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CredentialReference.self, from: data)
        #expect(decoded == original)
        #expect(String(data: data, encoding: .utf8)?.contains("provider.claude-acp.anthropic-api-key") == true)
    }

    @Test func comparableOrdersByRawValue() throws {
        let left = try CredentialReference(validating: "acp.agent-api-key")
        let right = try CredentialReference(validating: "zotero.api-key")
        #expect(left < right)
    }
}

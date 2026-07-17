import Testing
import Foundation
@testable import WikiFS

/// AC.15 — A redacted `DebugLog` payload is logged for the `addAction` bridge
/// — raw `PasswordField` values never reach Console.app/os_log. The
/// redaction helper scrubs secret-looking keys before the payload is logged.
@Suite struct RedactionTests {

    @Test func test_addAction_payload_redacted_before_log() {
        // An action payload with a password field (e.g. from a PasswordField
        // bound to "/form/apiKey"). The raw value must never appear in logs.
        let params: [String: Any] = [
            "name": "My Source",
            "apiKey": "super-secret-token-12345",
            "limit": 50,
            "format": "pdf"
        ]

        let redacted = RedactionHelper.redactActionPayload(action: "addSource", params: params)

        // The secret value must NOT appear in the redacted string.
        #expect(!redacted.contains("super-secret-token-12345"),
               "secret value leaked into redacted log: \(redacted)")

        // The placeholder MUST appear for the secret key.
        #expect(redacted.contains("***"), "secret value not replaced with placeholder: \(redacted)")

        // Non-secret values should be visible (useful for debugging).
        #expect(redacted.contains("My Source"), "non-secret value incorrectly redacted")
        #expect(redacted.contains("addSource"), "action name missing from redacted output")
    }

    @Test func test_secret_key_detection() {
        #expect(RedactionHelper.isSecretKey("password") == true)
        #expect(RedactionHelper.isSecretKey("passphrase") == true)
        #expect(RedactionHelper.isSecretKey("apiKey") == true)
        #expect(RedactionHelper.isSecretKey("api_key") == true)
        #expect(RedactionHelper.isSecretKey("userToken") == true)
        #expect(RedactionHelper.isSecretKey("credential") == true)
        #expect(RedactionHelper.isSecretKey("authHeader") == true)
        #expect(RedactionHelper.isSecretKey("bearerToken") == true)
        #expect(RedactionHelper.isSecretKey("otpCode") == true)

        #expect(RedactionHelper.isSecretKey("name") == false)
        #expect(RedactionHelper.isSecretKey("format") == false)
        #expect(RedactionHelper.isSecretKey("limit") == false)
        #expect(RedactionHelper.isSecretKey("label") == false)
    }

    @Test func test_multiple_secrets_all_redacted() {
        let params: [String: Any] = [
            "password": "pass1",
            "apiToken": "tok2",
            "secretKey": "key3",
            "name": "visible"
        ]
        let redacted = RedactionHelper.redactActionPayload(action: "test", params: params)
        #expect(!redacted.contains("pass1"))
        #expect(!redacted.contains("tok2"))
        #expect(!redacted.contains("key3"))
        #expect(redacted.contains("visible"))
    }
}

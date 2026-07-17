import Foundation

/// Redacts secret values from an `addAction` payload before it reaches
/// `DebugLog` (os_log → Console.app). Used by `JSONRenderView`'s message
/// handler to ensure `PasswordField` values never appear in logs.
///
/// The redaction is heuristic: since the action payload is a flat
/// `{ action, params }` with no type metadata, we scrub values whose keys
/// match common secret patterns (password, secret, key, token, credential).
/// This covers the form-primitives subset (PasswordField → apiKey, password,
/// token, etc.) and is conservative — if in doubt, redact.
///
/// Phase 4 formalizes keychain storage; this helper is used from Phase 1
/// onward to ensure redacted logging. AC.15 covers the test.
enum RedactionHelper {

    /// Keys whose values should be redacted. Matched case-insensitively
    /// via substring (e.g. "apiKey" contains "key", "userPassword" contains
    /// "password").
    private static let secretPatterns = [
        "password", "passphrase", "secret", "apikey", "api_key",
        "token", "credential", "auth", "bearer", "otp"
    ]

    /// Returns `true` if the key name suggests a secret value.
    static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return secretPatterns.contains { lower.contains($0) }
    }

    /// Produce a redacted string representation of an action payload.
    /// Secret values are replaced with `***`; non-secret values are stringified.
    static func redactActionPayload(action: String, params: [String: Any]) -> String {
        var redacted: [String: String] = [:]
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            if isSecretKey(key) {
                redacted[key] = "***"
            } else {
                redacted[key] = String(describing: value)
            }
        }
        return "action=\(action) params=\(redacted)"
    }
}

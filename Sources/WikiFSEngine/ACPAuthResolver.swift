import Foundation
import ACPModel

/// The outcome of deciding how (or whether) to authenticate against an ACP
/// agent after `initialize`. Produced by the PURE `ACPAuthDecision.resolve(…)`
/// helper, which is unit-tested directly — no live agent required.
///
/// Slice 3 of `plans/acp-backend-and-permissions.md`: the agent may advertise
/// `authMethods` in its `InitializeResponse`; if it does, the client must call
/// `Client.authenticate(authMethodId:credentials:)` before `newSession`. If it
/// doesn't, auth is skipped (some agents need none).
public enum ACPAuthDecision: Equatable, Sendable {
    /// The agent advertised no `authMethods` — skip `authenticate` entirely.
    case skip
    /// Authenticate against the chosen method, passing the configured API key as
    /// a credential under the conventional `"apiKey"` field.
    case authenticate(authMethodId: String, credentials: [String: String])
    /// The agent requires auth (`authMethods` is non-empty) but no API key is
    /// configured. Surfaced as a preflight error rather than crashing — the turn
    /// never starts.
    case missingCredentials
}

/// PURE auth-decision logic, extracted so it can be unit-tested without a live
/// agent subprocess. Given the agent's advertised `authMethods` and the
/// configured API key, decide whether to call `Client.authenticate` and with
/// what params.
enum ACPAuthResolver {

    /// The conventional ACP credential field name for an API-key secret.
    static let credentialKey = "apiKey"

    /// Decide the auth action.
    ///
    /// - If `authMethods` is nil or empty → `.skip` (the agent needs no auth).
    /// - If at least one method is advertised but `apiKey` is nil/blank →
    ///   `.missingCredentials` (surface a preflight error; never crash).
    /// - Otherwise → `.authenticate`, using the **first** advertised method's id
    ///   and the key under `credentialKey`. (ACP agents commonly advertise a
    ///   single API-key method; picking the first matches the common case. A
    ///   future UI can let the user choose among several.)
    static func resolve(authMethods: [AuthMethod]?, apiKey: String?) -> ACPAuthDecision {
        guard let methods = authMethods, let first = methods.first else {
            return .skip
        }
        guard let key = apiKey, !key.isEmpty else {
            return .missingCredentials
        }
        return .authenticate(
            authMethodId: first.id,
            credentials: [Self.credentialKey: key]
        )
    }
}

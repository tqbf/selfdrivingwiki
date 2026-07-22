import Foundation
import ACPModel

/// #727: the outcome of inspecting a provider error for quota exhaustion.
/// `nil` means "not a quota error — handle normally."
public struct QuotaSignal: Sendable, Equatable {
    public let providerId: String
    public let resetTime: Date?
    public let kind: Kind

    public enum Kind: Sendable, Equatable, Codable {
        case claudeSession           // "session limit" / "Opus limit"
        case claudeWeekly            // "weekly limit"
        case zaiErrorCode(Int)       // 1310/1316/1317/1318/1319/1308

        enum CodingKeys: String, CodingKey {
            case type
            case code
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            switch type {
            case "claudeSession":
                self = .claudeSession
            case "claudeWeekly":
                self = .claudeWeekly
            case "zaiErrorCode":
                let code = try container.decode(Int.self, forKey: .code)
                self = .zaiErrorCode(code)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Invalid quota signal kind: \(type)"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .claudeSession:
                try container.encode("claudeSession", forKey: .type)
            case .claudeWeekly:
                try container.encode("claudeWeekly", forKey: .type)
            case .zaiErrorCode(let code):
                try container.encode("zaiErrorCode", forKey: .type)
                try container.encode(code, forKey: .code)
            }
        }
    }
}

/// #727: which provider family a provider id belongs to, so the detector
/// applies the right heuristic (Claude text vs. z.ai numeric code).
public enum ProviderFamily: Sendable, Equatable {
    case claude
    case zai
    case unknown
}

/// #727: pure, side-effect-free detection of quota-exhaustion errors.
///
/// The swift-acp SDK talks to agents over **stdio JSON-RPC**, *not* HTTP.
/// `sendPrompt` throws `ClientError.agentError(JSONRPCError)` where
/// `JSONRPCError` exposes only `.code: Int`, `.message: String`, and
/// `.data: AnyCodable?`. There is **no HTTP body, status code, or response
/// header** at any catch site. Detection operates **solely on the
/// `JSONRPCError`**.
///
/// - Claude: match quota phrases ("session limit" / "weekly limit" /
///   "Opus limit") in `JSONRPCError.message`.
/// - z.ai/GLM: match the numeric exhaustion code on `JSONRPCError.code` (or
///   parse it from `.message` / `.data`). Exclude transient codes.
public enum ProviderQuotaDetector {

    // MARK: - Exhaustion + transient code sets

    /// z.ai/GLM quota-exhaustion codes (from the GLM API docs).
    private static let zaiExhaustionCodes: Set<Int> = [
        1310, 1316, 1317, 1318, 1319, 1308
    ]

    /// z.ai/GLM transient (retryable) codes — NOT quota. These must NOT mark
    /// a provider dead.
    private static let zaiTransientCodes: Set<Int> = [
        1302, 1305, 1313
    ]

    // MARK: - Default reset intervals

    /// Default reset time when the error carried no timestamp, per kind.
    static func defaultResetInterval(for kind: QuotaSignal.Kind) -> TimeInterval {
        switch kind {
        case .claudeSession: return 5 * 3600       // +5 hours
        case .claudeWeekly: return 7 * 86400      // +7 days
        case .zaiErrorCode: return 3600           // +1 hour
        }
    }

    // MARK: - Provider family inference

    /// Infer the provider family from the provider id (and optionally its
    /// label/command). Used to select the right heuristic.
    /// - `.claude` → Claude text heuristic.
    /// - `.zai` → z.ai/GLM numeric code heuristic.
    /// - `.unknown` → run BOTH heuristics, return the first signal
    ///   (conservative — never drops a healthy provider).
    public static func providerFamily(forProviderId providerId: String) -> ProviderFamily {
        let lower = providerId.lowercased()
        if lower.contains("claude") { return .claude }
        if lower.contains("glm") || lower.contains("zai") || lower.contains("z-ai") {
            return .zai
        }
        return .unknown
    }

    // MARK: - Detection entry point

    /// Inspect `error` for a quota-exhaustion signal. `providerId` selects
    /// the heuristic family (Claude text vs. z.ai code). Returns nil for any
    /// non-quota error (transport/process errors, transient z.ai codes).
    ///
    /// - Parameter providerId: the ACP provider id (threaded via
    ///   `HintKey.acpProviderId`).
    /// - Parameter error: the raw error caught at the `sendPrompt` call site.
    ///   Only `ClientError.agentError(JSONRPCError)` carries quota signal.
    public static func detect(
        providerId: String,
        error: Error
    ) -> QuotaSignal? {
        // 1. Unwrap the JSONRPCError: only `.agentError` carries server-side
        //    quota signal. Transport/process errors are never quota.
        guard let clientError = error as? ClientError,
              case .agentError(let rpc) = clientError else {
            return nil
        }

        let family = providerFamily(forProviderId: providerId)

        switch family {
        case .claude:
            return detectClaude(providerId: providerId, rpc: rpc)
        case .zai:
            return detectZai(providerId: providerId, rpc: rpc)
        case .unknown:
            // Run both heuristics; return the first signal (conservative).
            if let claudeSignal = detectClaude(providerId: providerId, rpc: rpc) {
                return claudeSignal
            }
            return detectZai(providerId: providerId, rpc: rpc)
        }
    }

    // MARK: - Claude heuristic (text-based)

    /// Claude quota phrases are matched (case-insensitive substring) on
    /// `JSONRPCError.message`. The agent surfaces its server-side error text
    /// here.
    private static func detectClaude(
        providerId: String,
        rpc: JSONRPCError
    ) -> QuotaSignal? {
        let msg = rpc.message.lowercased()

        // Weekly limit check first — prefer the longer window when both match.
        let weeklyPhrases = [
            "weekly limit",
            "your usage limit has been reached"
        ]
        for phrase in weeklyPhrases where msg.contains(phrase) {
            return QuotaSignal(
                providerId: providerId,
                resetTime: Date(timeIntervalSinceNow: defaultResetInterval(for: .claudeWeekly)),
                kind: .claudeWeekly
            )
        }

        let sessionPhrases = [
            "session limit",
            "opus limit",
            "op limit"
        ]
        for phrase in sessionPhrases where msg.contains(phrase) {
            return QuotaSignal(
                providerId: providerId,
                resetTime: Date(timeIntervalSinceNow: defaultResetInterval(for: .claudeSession)),
                kind: .claudeSession
            )
        }

        return nil
    }

    // MARK: - z.ai heuristic (numeric code-based)

    /// z.ai/GLM quota detection: three extraction attempts, first hit wins.
    /// 1. `rpc.code` — if it's a whitelisted exhaustion code, use it.
    /// 2. `rpc.message` — parse a numeric code from text like "error code: 1310".
    /// 3. `rpc.data?.value` — String (recurse message), Int (compare),
    ///    [String: Any] (look for error/code/error_code keys + next_flush_time).
    private static func detectZai(
        providerId: String,
        rpc: JSONRPCError
    ) -> QuotaSignal? {
        // 1. rpc.code
        if let code = checkZaiCode(rpc.code) {
            return QuotaSignal(
                providerId: providerId,
                resetTime: parseZaiResetTime(from: rpc.data) ??
                    Date(timeIntervalSinceNow: defaultResetInterval(for: code.kind)),
                kind: code.kind
            )
        }

        // 2. rpc.message — parse a numeric code
        if let codeFromMsg = parseCodeFromText(rpc.message),
           let code = checkZaiCode(codeFromMsg) {
            return QuotaSignal(
                providerId: providerId,
                resetTime: parseZaiResetTime(from: rpc.data) ??
                    Date(timeIntervalSinceNow: defaultResetInterval(for: code.kind)),
                kind: code.kind
            )
        }

        // 3. rpc.data?.value
        if let data = rpc.data {
            return detectZaiFromData(providerId: providerId, value: data.value, rpc: rpc)
        }

        return nil
    }

    // MARK: - z.ai code validation

    private struct ZaiCodeResult {
        let code: Int
        let kind: QuotaSignal.Kind
    }

    /// Check whether `code` is a whitelisted z.ai exhaustion code. Returns nil
    /// for non-quota codes (including transient ones we exclude).
    private static func checkZaiCode(_ code: Int) -> ZaiCodeResult? {
        // Exclude transient codes first.
        if zaiTransientCodes.contains(code) { return nil }
        if zaiExhaustionCodes.contains(code) {
            return ZaiCodeResult(code: code, kind: .zaiErrorCode(code))
        }
        return nil
    }

    /// Parse a 4-digit numeric code from text like "error code: 1310" or
    /// "code=1316". Returns the first match or nil.
    private static func parseCodeFromText(_ text: String) -> Int? {
        let pattern = #"code[:\s=]+(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           match.numberOfRanges > 1,
           let codeRange = Range(match.range(at: 1), in: text),
           let code = Int(text[codeRange]) {
            return code
        }
        return nil
    }

    /// Inspect `rpc.data?.value` for a z.ai quota code.
    private static func detectZaiFromData(
        providerId: String,
        value: Any,
        rpc: JSONRPCError
    ) -> QuotaSignal? {
        if let str = value as? String {
            if let codeFromStr = parseCodeFromText(str),
               let code = checkZaiCode(codeFromStr) {
                return QuotaSignal(
                    providerId: providerId,
                    resetTime: parseZaiResetTime(from: rpc.data) ??
                        Date(timeIntervalSinceNow: defaultResetInterval(for: code.kind)),
                    kind: code.kind
                )
            }
        } else if let intVal = value as? Int {
            if let code = checkZaiCode(intVal) {
                return QuotaSignal(
                    providerId: providerId,
                    resetTime: parseZaiResetTime(from: rpc.data) ??
                        Date(timeIntervalSinceNow: defaultResetInterval(for: code.kind)),
                    kind: code.kind
                )
            }
        } else if let dict = value as? [String: Any] {
            // Look for an error code in a nested structure.
            for key in ["error", "code", "error_code"] {
                if let nested = dict[key] {
                    if let intVal = nested as? Int,
                       let code = checkZaiCode(intVal) {
                        return QuotaSignal(
                            providerId: providerId,
                            resetTime: parseZaiResetTime(from: rpc.data) ??
                                Date(timeIntervalSinceNow: defaultResetInterval(for: code.kind)),
                            kind: code.kind
                        )
                    }
                    if let strVal = nested as? String,
                       let codeFromStr = parseCodeFromText(strVal),
                       let code = checkZaiCode(codeFromStr) {
                        return QuotaSignal(
                            providerId: providerId,
                            resetTime: parseZaiResetTime(from: rpc.data) ??
                                Date(timeIntervalSinceNow: defaultResetInterval(for: code.kind)),
                            kind: code.kind
                        )
                    }
                }
            }
        }
        return nil
    }

    // MARK: - z.ai reset time parsing

    /// Extract a reset/flush time from `rpc.data?.value`. z.ai returns a
    /// `next_flush_time` (ISO-8601) or `reset_time` in the data payload.
    private static func parseZaiResetTime(from data: AnyCodable?) -> Date? {
        guard let data else { return nil }
        if let dict = data.value as? [String: Any] {
            let isoFormatter = ISO8601DateFormatter()
            for key in ["next_flush_time", "reset_time"] {
                if let str = dict[key] as? String,
                   let date = isoFormatter.date(from: str) {
                    return date
                }
            }
        }
        return nil
    }
}

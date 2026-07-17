import Foundation

/// A small, pure HTML entity decoder.
///
/// Covers the named entities that actually appear in body prose plus the full
/// numeric forms (`&#NN;` decimal and `&#xNN;`/`&#XNN;` hex). It is deliberately
/// NOT the full WHATWG named-entity table — the converted Markdown is a
/// summarization input, not a fidelity-critical render — but it handles the common
/// cases the spec flags (`&amp; &lt; &gt; &quot; &#39; &nbsp;` …). Tolerant: an
/// unterminated or unrecognized `&…` is left verbatim rather than dropped or
/// crashing.
public enum HTMLEntities {

    /// Escape `&`, `<`, `>` for safe embedding in HTML text. The single source of
    /// truth for the three-char escape formerly duplicated as private `escape(_:)`
    /// in `ChatWebView` and `MarkdownHTMLRenderer` (and the
    /// `escapeAttribute`/`escapePreservingBreaks` wrappers that build on it).
    /// `public` so the `WikiFS` app target can reach it; `decode` stays module-
    /// internal. See issue #502 (cross-module dedup, L2).
    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The named entities we recognize. Lowercase-keyed; lookups are case-sensitive
    /// for named entities (matching how browsers treat e.g. `&AMP;` vs `&amp;` —
    /// here we accept the canonical lowercase forms plus a few common capitalized
    /// ones).
    private static let named: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": "\u{00A0}",
        "copy": "©",
        "reg": "®",
        "trade": "™",
        "hellip": "…",
        "mdash": "—",
        "ndash": "–",
        "lsquo": "‘",
        "rsquo": "’",
        "ldquo": "“",
        "rdquo": "”",
        "laquo": "«",
        "raquo": "»",
        "deg": "°",
        "plusmn": "±",
        "times": "×",
        "divide": "÷",
        "euro": "€",
        "pound": "£",
        "cent": "¢",
        "yen": "¥",
        "sect": "§",
        "para": "¶",
        "middot": "·",
        "bull": "•",
        "dagger": "†",
        "frac12": "½",
        "frac14": "¼",
        "frac34": "¾",
    ]

    /// Decode every `&entity;` in `s`. A lone `&` not starting a valid entity, and an
    /// unterminated `&…` (no closing `;` within a sane window), are passed through
    /// literally. Bounded by the input length.
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        let chars = Array(s)
        var i = 0
        let n = chars.count
        while i < n {
            guard chars[i] == "&" else {
                out.append(chars[i])
                i += 1
                continue
            }
            // Find the terminating ';' within a bounded window (entities are short).
            // Cap at 32 chars so a stray '&' in prose doesn't scan the whole string.
            let maxScan = min(n, i + 33)
            var semi = -1
            var j = i + 1
            while j < maxScan {
                let c = chars[j]
                if c == ";" { semi = j; break }
                // An entity body is alnum (named) or '#'+hex/dec. Anything else means
                // this '&' isn't an entity — bail and emit it literally.
                if !(c.isLetter || c.isNumber || c == "#") { break }
                j += 1
            }
            guard semi > i + 1 else {
                out.append("&")
                i += 1
                continue
            }
            let body = String(chars[(i + 1)..<semi])
            if let decoded = decodeBody(body) {
                out.append(decoded)
                i = semi + 1
            } else {
                out.append("&")
                i += 1
            }
        }
        return out
    }

    /// Decode the inside of an entity (between `&` and `;`). Numeric forms first,
    /// then the named table. Returns `nil` for an unrecognized body so the caller
    /// emits the literal `&`.
    private static func decodeBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let numPart = body.dropFirst()
            let scalarValue: UInt32?
            if numPart.first == "x" || numPart.first == "X" {
                scalarValue = UInt32(numPart.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(numPart, radix: 10)
            }
            guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
            return String(scalar)
        }
        return named[body]
    }
}

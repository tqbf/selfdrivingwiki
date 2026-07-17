import Foundation

/// Pure Swift helper that base64-encodes a json-render spec JSON string for
/// safe injection into a WKWebView via `window.WikiJSONRender.applyBase64`.
///
/// Base64 avoids the quote/backslash/newline escaping hazards of interpolating
/// raw JSON into a JavaScript string literal. The JS side (`applyBase64`)
/// decodes via `atob` + `TextDecoder` + `JSON.parse`.
///
/// Used by `JSONRenderView` to deliver the spec to the webview. Unit-tested by
/// `JSONRenderPayloadEncoderTests` (AC.4) with payloads containing quotes,
/// backslashes, and newlines.
enum JSONRenderPayloadEncoder {

    /// Encode a JSON string to base64 for `applyBase64`.
    /// - Parameter json: A JSON string (e.g. from `JSONSerialization`).
    /// - Returns: Base64-encoded string safe to interpolate in a JS call.
    static func encode(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
    }

    /// Encode a JSON-serializable object to base64 for `applyBase64`.
    /// - Parameter spec: A `[String: Any]` dictionary conforming to JSON.
    /// - Returns: Base64-encoded JSON string.
    /// - Throws: `JSONSerialization` error if the object is not serializable.
    static func encode(spec: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])
        return encode(String(data: data, encoding: .utf8) ?? "")
    }

    /// Convenience: build the JavaScript call string that applies the spec.
    /// - Parameter b64: The base64-encoded spec (from `encode`).
    /// - Returns: `window.WikiJSONRender.applyBase64('<b64>')` — safe because
    ///   base64 contains only `[A-Za-z0-9+/=]`, no quotes or backslashes.
    static func applyScript(_ b64: String) -> String {
        "window.WikiJSONRender.applyBase64('\(b64)')"
    }
}

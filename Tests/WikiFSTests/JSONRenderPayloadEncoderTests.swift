import Testing
import Foundation
@testable import WikiFS

/// AC.4 — Large/quoted spec JSON is delivered to the webview without breaking
/// on quotes. The encoder base64-encodes the JSON so no quote/backslash/
/// newline escaping is needed on the JS side.
@Suite struct JSONRenderPayloadEncoderTests {

    @Test func test_encode_round_trips_quoted_payload() throws {
        // A spec with quotes, backslashes, newlines, and Unicode — the exact
        // hazards that motivated base64 over raw JSON interpolation.
        let tricky = """
        {"label":"He said \\"hi\\"\\nNew line","value":"C:\\\\Users\\\\test"}
        """
        let b64 = JSONRenderPayloadEncoder.encode(tricky)

        // Base64 output contains only safe characters — no quotes to escape.
        #expect(!b64.contains("\""), "base64 must not contain quotes")
        #expect(!b64.contains("\\"), "base64 must not contain backslashes")

        // Round-trip: decode the base64 back to the original JSON.
        let decoded = Data(base64Encoded: b64).map { String(data: $0, encoding: .utf8) }
        #expect(decoded == tricky, "base64 round-trip failed for quoted payload")

        // The apply script interpolates the base64 in a JS string — safe
        // because base64 is [A-Za-z0-9+/=] only.
        let script = JSONRenderPayloadEncoder.applyScript(b64)
        #expect(script.contains("applyBase64('"), "apply script must call applyBase64")
    }

    @Test func test_encode_spec_object() throws {
        let spec: [String: Any] = [
            "root": "form",
            "elements": [
                "form": [
                    "type": "Stack",
                    "children": ["name", "btn"]
                ],
                "name": [
                    "type": "TextField",
                    "props": ["label": "Name", "value": ["$bindState": "/form/name"]]
                ],
                "btn": [
                    "type": "Button",
                    "props": ["label": "Add"],
                    "on": ["press": ["action": "addSource", "params": ["name": ["$state": "/form/name"]]]]
                ]
            ],
            "state": [:]
        ]
        let b64 = try JSONRenderPayloadEncoder.encode(spec: spec)
        #expect(!b64.isEmpty)

        // Decode and verify the spec survives the round-trip.
        let data = try #require(Data(base64Encoded: b64))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["root"] as? String == "form")
    }

    @Test func test_encode_unicode() throws {
        // Unicode (emoji, CJK) must survive the base64 round-trip.
        let json = #"{"label":"日本語 🎉 test"}"#
        let b64 = JSONRenderPayloadEncoder.encode(json)
        let decoded = String(data: try #require(Data(base64Encoded: b64)), encoding: .utf8)
        #expect(decoded == json, "unicode round-trip failed")
    }
}

import SwiftUI
import WikiFSCore

/// Phase 1.3 dev proof — a temporary app entry that renders the sample form
/// spec (TextField + PasswordField + NumberField + SelectField + Add Button)
/// in `JSONRenderView`. On clicking "Add", the `addSource` action round-trips
/// to Swift and is logged via `DebugLog` (redacted; no store write in Phase 1).
///
/// Opened from the View ▸ json-render Form Proof menu command (temporary —
/// Phase 3 replaces this with real provider/connection tabs).
struct JSONRenderDevProofView: View {
    @State private var lastAction: String = "(none)"

    var body: some View {
        VStack(spacing: 0) {
            JSONRenderView(specBase64: Self.specBase64) { action, params in
                DebugLog.reader("dev-proof action: \(RedactionHelper.redactActionPayload(action: action, params: params))")
                lastAction = "Received: \(action) (\(params.count) params)"
            }
            Divider()
            HStack {
                Text("Last action: \(lastAction)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .navigationTitle("json-render Form Proof")
        .frame(minWidth: 520, minHeight: 420)
    }

    /// The dev-proof form spec: TextField + PasswordField + NumberField +
    /// SelectField + an "Add" Button whose `addSource` action carries form
    /// values via `$state` expressions. Matches the spec in
    /// `JSONRenderScenarioTests.devProofSpecBase64`.
    static let specBase64: String = {
        let spec: [String: Any] = [
            "root": "form",
            "elements": [
                "form": [
                    "type": "Stack",
                    "children": ["name-field", "pass-field", "num-field", "sel-field", "add-btn"]
                ],
                "name-field": [
                    "type": "TextField",
                    "props": ["label": "Name", "value": ["$bindState": "/form/name"]]
                ],
                "pass-field": [
                    "type": "PasswordField",
                    "props": ["label": "API Key", "value": ["$bindState": "/form/apiKey"]]
                ],
                "num-field": [
                    "type": "NumberField",
                    "props": ["label": "Limit", "value": ["$bindState": "/form/limit"]]
                ],
                "sel-field": [
                    "type": "SelectField",
                    "props": [
                        "label": "Format",
                        "value": ["$bindState": "/form/format"],
                        "options": [
                            ["label": "Markdown", "value": "md"],
                            ["label": "PDF", "value": "pdf"]
                        ]
                    ]
                ],
                "add-btn": [
                    "type": "Button",
                    "props": ["label": "Add"],
                    "on": [
                        "press": [
                            "action": "addSource",
                            "params": [
                                "name": ["$state": "/form/name"],
                                "apiKey": ["$state": "/form/apiKey"],
                                "limit": ["$state": "/form/limit"],
                                "format": ["$state": "/form/format"]
                            ]
                        ]
                    ]
                ]
            ],
            "state": [:]
        ]
        do {
            return try JSONRenderPayloadEncoder.encode(spec: spec)
        } catch {
            DebugLog.reader("JSONRenderDevProofView: failed to encode spec: \(error)")
            return ""
        }
    }()
}

import Foundation
import JavaScriptCore

// renderer-asset-reference-extractor-helper
//
// A single-invocation SwiftPM executable that runs a renderer package's
// hash-approved reference-extractor JavaScript against bounded pinned input.
//
// Protocol (version 1):
//   stdin : one complete frame — 4-byte big-endian payload length, then a JSON
//           object: {"format":"sdw.renderer-asset-reference-extractor.v1",
//                     "extractorBytesBase64": ..., "entryFunction": ...,
//                     "primaryInputBase64": ...}
//   stdout: one complete JSON frame — 4-byte big-endian length, then
//           {"ok":true,"records":[{"role":"imageNode","reference":"..."}]}
//           or {"ok":false,"reason":"<redacted>"}
//   stderr: bounded redacted diagnostics only (never paths, source IDs,
//           titles, or content).
//
// The helper exposes NO DOM, filesystem, store, wiki index, bridge, native
// objects, or network APIs to the JavaScript: a fresh JSContext with no
// host-object bridging, no `console` backdoor, and no process environment.
// It is not an OS sandbox; it is JavaScript capability isolation. The parent
// enforces deadlines, output caps, and process-group termination.
//
// Every field is validated BEFORE decoding or evaluating. The helper exits
// after one invocation.

// MARK: - Limits (mirror the manifest contract ceilings; the parent enforces
// its own bounds before spawning, and the helper re-checks defensively)

private enum Bounds {
    static let maximumFrameBytes = 512 * 1_024
    static let maximumExtractorBytes = 256 * 1_024
    static let maximumPrimaryInputBytes = 256 * 1_024
    static let maximumExtractedReferenceCount = 256
    static let maximumReferenceLength = 512
    static let maximumOutputRecordsBytes = 256 * 1_024
    static let maximumEntryFunctionLength = 128
}

private enum HelperError: Error, CustomStringConvertible {
    case malformedFrame
    case oversizedFrame
    case malformedRequest
    case invalidFormat
    case invalidEntryFunction
    case invalidExtractorBytes
    case invalidPrimaryInput
    case tooManyRecords
    case malformedRecord
    case unresolvedEntry
    case evaluationFailed(String)
    case outputTooLarge

    var description: String {
        switch self {
        case .malformedFrame: "malformed frame"
        case .oversizedFrame: "oversized frame"
        case .malformedRequest: "malformed request"
        case .invalidFormat: "invalid format"
        case .invalidEntryFunction: "invalid entry function"
        case .invalidExtractorBytes: "invalid extractor bytes"
        case .invalidPrimaryInput: "invalid primary input"
        case .tooManyRecords: "too many records"
        case .malformedRecord: "malformed record"
        case .unresolvedEntry: "unresolved entry"
        case .evaluationFailed: "evaluation failed"
        case .outputTooLarge: "output too large"
        }
    }
}

// MARK: - Identifier-safety (mirrors rendererJavaScriptIdentifier in
// WikiFSTypes; duplicated here so the helper is self-contained and cannot
// drift from the host policy through a shared-module dependency)

private func isJavaScriptIdentifier(_ value: String) -> Bool {
    guard value.isEmpty == false,
          let first = value.first,
          first == "_" || first.isLetter,
          value.allSatisfy({ $0 == "_" || $0 == "$" || $0.isLetter || $0.isNumber })
    else { return false }
    let reserved: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "enum", "export",
        "extends", "false", "finally", "for", "function", "if", "import",
        "in", "instanceof", "let", "new", "null", "return", "static",
        "super", "switch", "this", "throw", "true", "try", "typeof", "var",
        "void", "while", "with", "yield", "undefined", "NaN", "Infinity",
    ]
    return reserved.contains(value) == false
}

private func isAllowedRole(_ value: String) -> Bool {
    value == "imageNode" || value == "groupBackground"
}

// MARK: - Fixed-length frame I/O

private func readUInt32BigEndian(from data: Data, at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        value = UInt32(base[offset]) << 24 | UInt32(base[offset + 1]) << 16
            | UInt32(base[offset + 2]) << 8 | UInt32(base[offset + 3])
    }
    return value
}

private func readFrame(_ handle: FileHandle) throws -> Data {
    let header = handle.readData(ofLength: 4)
    guard header.count == 4 else { throw HelperError.malformedFrame }
    let length = Int(readUInt32BigEndian(from: header, at: 0))
    guard length > 0, length <= Bounds.maximumFrameBytes else { throw HelperError.oversizedFrame }
    let payload = handle.readData(ofLength: length)
    guard payload.count == length else { throw HelperError.malformedFrame }
    // Reject trailing data: the helper handles exactly one frame.
    let extra = handle.readData(ofLength: 1)
    guard extra.isEmpty else { throw HelperError.malformedFrame }
    return payload
}

private func writeFrame(_ data: Data) throws {
    precondition(data.count <= UInt32.max)
    var header = Data()
    header.append(UInt8((data.count >> 24) & 0xff))
    header.append(UInt8((data.count >> 16) & 0xff))
    header.append(UInt8((data.count >> 8) & 0xff))
    header.append(UInt8(data.count & 0xff))
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(data)
}

private func writeJSONFrame(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    guard data.count <= Bounds.maximumOutputRecordsBytes else { throw HelperError.outputTooLarge }
    try writeFrame(data)
}

// MARK: - Request/record validation

private func record(from value: Any) throws -> (role: String, reference: String) {
    guard let dictionary = value as? [String: Any],
          let role = dictionary["role"] as? String,
          let reference = dictionary["reference"] as? String,
          isAllowedRole(role),
          reference.isEmpty == false,
          reference.count <= Bounds.maximumReferenceLength
    else { throw HelperError.malformedRecord }
    return (role, reference)
}

private func run() {
    do {
        let payload = try readFrame(FileHandle.standardInput)
        let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        guard let request else { throw HelperError.malformedRequest }

        guard request["format"] as? String == "sdw.renderer-asset-reference-extractor.v1" else {
            throw HelperError.invalidFormat
        }
        guard let entryFunction = request["entryFunction"] as? String,
              entryFunction.count <= Bounds.maximumEntryFunctionLength,
              isJavaScriptIdentifier(entryFunction) else {
            throw HelperError.invalidEntryFunction
        }
        guard let extractorB64 = request["extractorBytesBase64"] as? String,
              let extractorBytes = Data(base64Encoded: extractorB64),
              extractorBytes.count > 0, extractorBytes.count <= Bounds.maximumExtractorBytes,
              let extractorSource = String(data: extractorBytes, encoding: .utf8) else {
            throw HelperError.invalidExtractorBytes
        }
        guard let primaryB64 = request["primaryInputBase64"] as? String,
              let primaryInput = Data(base64Encoded: primaryB64),
              primaryInput.count <= Bounds.maximumPrimaryInputBytes else {
            throw HelperError.invalidPrimaryInput
        }

        guard let context = JSContext() else { throw HelperError.evaluationFailed("context unavailable") }
        // No bridged objects: no `console`, no `require`, no `process`, no
        // timers. A reference to a missing global throws at evaluation time
        // and is surfaced as a redacted failure.
        context.exceptionHandler = { _, value in
            // Keep the exception in a local so diagnostics stay bounded and
            // redacted; we do not tee it to stderr verbatim.
            _ = value?.toString()
        }
        let evaluationResult = context.evaluateScript(extractorSource)
        guard evaluationResult != nil else {
            throw HelperError.evaluationFailed("extractor did not evaluate")
        }
        guard let entry = context.objectForKeyedSubscript(entryFunction as NSString),
              entry.isObject else { throw HelperError.unresolvedEntry }

        // Pass the primary input to the entry function as a UTF-8 string. A
        // raw JSContext has no `TextDecoder`, so a reviewed extractor must
        // not depend on Web APIs; the host decodes the bounded bytes and the
        // extractor receives one string argument.
        guard let primaryText = String(data: primaryInput, encoding: .utf8) else {
            throw HelperError.invalidPrimaryInput
        }
        let result = entry.call(withArguments: [primaryText])
        guard let result, result.isObject,
              let resultDictionary = result.toDictionary() as? [String: Any] else {
            throw HelperError.evaluationFailed("entry returned no result")
        }
        guard let records = resultDictionary["records"] as? [Any] else {
            throw HelperError.evaluationFailed("entry returned no records")
        }
        guard records.count <= Bounds.maximumExtractedReferenceCount else {
            throw HelperError.tooManyRecords
        }
        var validated: [[String: String]] = []
        var seen = Set<String>()
        for rawRecord in records {
            let parsed = try record(from: rawRecord)
            // Deduplicate by role+reference so a duplicate record cannot
            // inflate the allowlist.
            let key = "\(parsed.role)\u{1f}\(parsed.reference)"
            guard seen.insert(key).inserted else { throw HelperError.malformedRecord }
            validated.append(["role": parsed.role, "reference": parsed.reference])
        }

        let response: [String: Any] = ["ok": true, "records": validated]
        try writeJSONFrame(response)
    } catch {
        do {
            let reason: String
            if let helperError = error as? HelperError {
                reason = helperError.description
            } else {
                reason = "failure"
            }
            try writeJSONFrame(["ok": false, "reason": reason])
        } catch {
            // Even the failure frame is bounded; if it cannot be written
            // there is nothing more to do. Exit nonzero.
            exit(2)
        }
        exit(1)
    }
}

run()

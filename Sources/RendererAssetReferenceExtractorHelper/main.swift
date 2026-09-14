import Foundation
import JavaScriptCore
#if canImport(Darwin)
import Darwin
#endif

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
//
// Failsafes (#1259): supervision is the parent's contract, but a parent that
// dies without killing the process group — a test crash, a SIGKILL, a
// parallel-load flake — must not leave a non-terminating extractor spinning
// a full core forever. The helper therefore arms two host-side failsafes
// BEFORE reading its frame, and neither is visible to the JavaScript (they
// live in the Swift host; the JSContext still sees no timers and no way to
// learn about time):
//
//   1. Self-deadline. A fixed 60 s ceiling — six times the manifest
//      contract's maximum declared extractor deadline (10 s,
//      `RendererAssetConstraints.maximumExtractorExecutionSeconds`) — after
//      which the helper exits(3) no matter what it is doing.
//   2. Orphan detection. The parent PID recorded at startup is polled; when
//      it changes (reparented, i.e. the supervisor died) or was already
//      launchd at birth, the helper exits(4) within one poll interval.
//
// A stdout write that cannot complete exits nonzero rather than hanging or
// spinning: SIGPIPE is ignored and frames are delivered with raw write(2).

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

    // Failsafe ceilings. The self-deadline is deliberately far above any
    // legitimate extraction (the manifest contract caps declared deadlines
    // at 10 s), so it can only ever fire on a run that is already lost.
    static let selfDeadlineSeconds = 60
    static let orphanPollMilliseconds = 1_000
    // Overrides may only SHORTEN a ceiling (a shorter deadline is strictly
    // safer), and never below a floor that keeps the poll negligible.
    static let minimumSelfDeadlineOverrideSeconds = 1
    static let minimumOrphanPollOverrideMilliseconds = 50
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
    case stdoutUnwritable

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
        case .stdoutUnwritable: "output unwritable"
        }
    }
}

// Exit codes that report which failsafe fired, so an autopsy of a dead
// helper can distinguish the outcomes. 0 (success), 1 (extraction failure,
// ok:false frame written), and 2 (failure frame unwritable) are the
// protocol outcomes; 3+ are failsafes and usage.
private enum FailsafeExitCode {
    static let selfDeadlineExceeded: Int32 = 3
    static let orphaned: Int32 = 4
    static let usage: Int32 = 64
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

/// Write all of `data` to stdout with raw write(2). A dead stdout surfaces
/// as EPIPE (false) instead of an ObjC exception Foundation cannot throw
/// across, and SIGPIPE is ignored at startup — so a vanished parent turns
/// into a clean nonzero exit instead of an unkillable spin (#1259).
private func writeAllToStandardOutput(_ data: Data) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var cursor = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
        var remaining = raw.count
        while remaining > 0 {
            let written = write(STDOUT_FILENO, cursor, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            cursor += written
            remaining -= written
        }
        return true
    }
}

private func writeFrame(_ data: Data) throws {
    precondition(data.count <= UInt32.max)
    var header = Data()
    header.append(UInt8((data.count >> 24) & 0xff))
    header.append(UInt8((data.count >> 16) & 0xff))
    header.append(UInt8((data.count >> 8) & 0xff))
    header.append(UInt8(data.count & 0xff))
    guard writeAllToStandardOutput(header), writeAllToStandardOutput(data) else {
        throw HelperError.stdoutUnwritable
    }
}

private func writeJSONFrame(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    guard data.count <= Bounds.maximumOutputRecordsBytes else { throw HelperError.outputTooLarge }
    try writeFrame(data)
}

// MARK: - Failsafes (defense in depth inside the helper)

/// One bounded static diagnostic line, written best-effort: the failsafe
/// path must never block, throw, or fail to terminate.
private func bestEffortStderrDiagnostic(_ line: String) {
    let message = Array((line + "\n").utf8)
    _ = message.withUnsafeBufferPointer { buffer in
        write(STDERR_FILENO, buffer.baseAddress, buffer.count)
    }
}

/// Failsafe timing. Only shortening overrides are accepted, so no caller —
/// including a hostile one that can already choose the whole command line —
/// can weaken the guarantees; the production client passes no arguments.
private struct FailsafeConfiguration {
    var selfDeadlineSeconds: Int
    var orphanPollMilliseconds: Int
}

private func overrideValue(_ prefix: String, _ argument: String) -> String? {
    guard argument.hasPrefix(prefix) else { return nil }
    return String(argument.dropFirst(prefix.count))
}

/// Returns nil when any argument is unrecognized or out of range, which the
/// caller treats as a usage error: this helper is spawned argument-free in
/// production, so anything else is a mistake worth failing fast on.
private func parseFailsafeConfiguration(_ arguments: [String]) -> FailsafeConfiguration? {
    var configuration = FailsafeConfiguration(
        selfDeadlineSeconds: Bounds.selfDeadlineSeconds,
        orphanPollMilliseconds: Bounds.orphanPollMilliseconds)
    for argument in arguments {
        if let value = overrideValue("--self-deadline-seconds=", argument),
           let seconds = Int(value),
           seconds >= Bounds.minimumSelfDeadlineOverrideSeconds {
            configuration.selfDeadlineSeconds = min(seconds, Bounds.selfDeadlineSeconds)
        } else if let value = overrideValue("--orphan-poll-milliseconds=", argument),
                  let milliseconds = Int(value),
                  milliseconds >= Bounds.minimumOrphanPollOverrideMilliseconds {
            configuration.orphanPollMilliseconds = min(milliseconds, Bounds.orphanPollMilliseconds)
        } else {
            return nil
        }
    }
    return configuration
}

/// Arm both failsafes BEFORE the frame read, so every later phase — a
/// blocked stdin read, a stuck JavaScript loop, a blocked stdout write — is
/// covered. The returned timers must stay retained by the caller's frame
/// for the life of the process.
private func armFailsafes(
    _ configuration: FailsafeConfiguration
) -> (deadline: DispatchSourceTimer, orphanPoll: DispatchSourceTimer) {
    // Orphaned at birth: launchd as the recorded parent means there is no
    // supervisor and never was one — this helper is always spawned as a
    // child of a live app, daemon, or test process.
    guard getppid() != 1 else {
        bestEffortStderrDiagnostic("orphaned at startup; exiting")
        exit(FailsafeExitCode.orphaned)
    }
    let initialParentProcessID = getppid()
    let queue = DispatchQueue(label: "renderer-asset-reference-extractor-helper.failsafes")

    let deadline = DispatchSource.makeTimerSource(queue: queue)
    deadline.setEventHandler {
        bestEffortStderrDiagnostic("self-deadline exceeded; exiting")
        exit(FailsafeExitCode.selfDeadlineExceeded)
    }
    deadline.schedule(deadline: .now() + .seconds(configuration.selfDeadlineSeconds))
    deadline.resume()

    let orphanPoll = DispatchSource.makeTimerSource(queue: queue)
    orphanPoll.setEventHandler {
        if getppid() != initialParentProcessID {
            bestEffortStderrDiagnostic("supervisor disappeared; exiting")
            exit(FailsafeExitCode.orphaned)
        }
    }
    orphanPoll.schedule(
        deadline: .now() + .milliseconds(configuration.orphanPollMilliseconds),
        repeating: .milliseconds(configuration.orphanPollMilliseconds))
    orphanPoll.resume()

    return (deadline, orphanPoll)
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
            // Even the failure frame is bounded; if it cannot be written —
            // including a dead stdout — there is nothing more to do. Exit
            // nonzero rather than continue.
            exit(2)
        }
        exit(1)
    }
}

// Failsafes first: they must cover every later phase, including a blocked
// frame read, a stuck extraction, and an unwritable response. The sources
// stay retained by this top-level frame for the life of the process.
signal(SIGPIPE, SIG_IGN)
guard let failsafes = parseFailsafeConfiguration(Array(CommandLine.arguments.dropFirst())) else {
    bestEffortStderrDiagnostic("unrecognized argument")
    exit(FailsafeExitCode.usage)
}
let failsafeSources = armFailsafes(failsafes)
run()

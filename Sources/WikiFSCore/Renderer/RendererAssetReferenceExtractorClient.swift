import Foundation
import WikiFSTypes

// MARK: - RendererAssetReferenceExtractorClient

/// Runs the hash-approved reference-extractor helper for the revision-5
/// `assetRead` authority.
///
/// The client sends the package's reviewed extractor JavaScript bytes, the
/// identifier-safe entry function, and the bounded pinned primary input to
/// the single-invocation helper over one framed stdin/stdout exchange
/// (protocol v1). It validates the complete frame and every field before
/// spawn, enforces the declared deadline plus stdout/stderr caps through the
/// repository's nonblocking process-group runner, and terminates and reaps
/// the helper on timeout. Every failure mode surfaces as zero records: the
/// caller fails closed to no admitted assets and preserves source/raw
/// fallback.
public enum RendererAssetReferenceExtractorClient {

    public struct Request: Sendable {
        public let helperURL: URL
        public let extractorBytes: Data
        public let entryFunction: String
        public let primaryInput: Data
        public let maxExtractorInputBytes: Int
        public let maxExtractorOutputBytes: Int
        public let maxReferenceCount: Int
        public let maxExecutionSeconds: Int
        /// Total stdout cap for the helper's framed JSON response.
        public let stdoutLimit: Int
        /// Total stderr cap for the helper's redacted diagnostics.
        public let stderrLimit: Int

        public init(
            helperURL: URL,
            extractorBytes: Data,
            entryFunction: String,
            primaryInput: Data,
            maxExtractorInputBytes: Int,
            maxExtractorOutputBytes: Int,
            maxReferenceCount: Int,
            maxExecutionSeconds: Int,
            stdoutLimit: Int,
            stderrLimit: Int
        ) {
            self.helperURL = helperURL
            self.extractorBytes = extractorBytes
            self.entryFunction = entryFunction
            self.primaryInput = primaryInput
            self.maxExtractorInputBytes = maxExtractorInputBytes
            self.maxExtractorOutputBytes = maxExtractorOutputBytes
            self.maxReferenceCount = maxReferenceCount
            self.maxExecutionSeconds = maxExecutionSeconds
            self.stdoutLimit = stdoutLimit
            self.stderrLimit = stderrLimit
        }
    }

    /// The validated outcome: an ordered, deduplicated list of
    /// `{role, reference}` records, or an extraction failure reason. A
    /// timeout, exception, malformed output, undeclared role, excessive
    /// output, or non-contextual reference fails closed.
    public struct ExtractedRecord: Sendable, Equatable {
        public let role: RendererAssetRole
        public let reference: String

        public init(role: RendererAssetRole, reference: String) {
            self.role = role
            self.reference = reference
        }
    }

    public struct Outcome: Sendable, Equatable {
        public let records: [ExtractedRecord]
        public let failureReason: String?

        public init(records: [ExtractedRecord], failureReason: String?) {
            self.records = records
            self.failureReason = failureReason
        }

        public static let empty = Outcome(records: [], failureReason: nil)
    }

    public enum ClientError: Error, Sendable, Equatable, CustomStringConvertible {
        case helperMissingOrInvalid
        case invalidRequest(String)
        case malformedResponse
        case helperFailed(String)
        case processError(String)

        public var description: String {
            switch self {
            case .helperMissingOrInvalid: "reference-extractor helper is missing or invalid"
            case let .invalidRequest(detail): "invalid reference-extractor request: \(detail)"
            case .malformedResponse: "reference-extractor helper returned a malformed response"
            case let .helperFailed(reason): "reference-extractor helper failed: \(reason)"
            case let .processError(detail): "reference-extractor process error: \(detail)"
            }
        }
    }

    /// Frame a request: 4-byte big-endian length prefix + JSON payload.
    public static func frameRequest(_ request: Request) throws -> Data {
        guard rendererJavaScriptIdentifier(request.entryFunction),
              request.entryFunction.count <= 128,
              request.extractorBytes.count > 0,
              request.extractorBytes.count <= request.maxExtractorInputBytes,
              request.primaryInput.count <= request.maxExtractorInputBytes else {
            throw ClientError.invalidRequest("pre-spawn field validation failed")
        }
        let payload: [String: Any] = [
            "format": "sdw.renderer-asset-reference-extractor.v1",
            "extractorBytesBase64": request.extractorBytes.base64EncodedString(),
            "entryFunction": request.entryFunction,
            "primaryInputBase64": request.primaryInput.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= request.maxExtractorOutputBytes else {
            throw ClientError.invalidRequest("framed request exceeds output bound")
        }
        return lengthPrefixed(data)
    }

    public static func lengthPrefixed(_ data: Data) -> Data {
        precondition(data.count <= UInt32.max)
        var result = Data()
        result.append(UInt8((data.count >> 24) & 0xff))
        result.append(UInt8((data.count >> 16) & 0xff))
        result.append(UInt8((data.count >> 8) & 0xff))
        result.append(UInt8(data.count & 0xff))
        result.append(data)
        return result
    }

    /// Strip a 4-byte big-endian length prefix and return the JSON payload.
    /// Returns `Any?` (mirrors `JSONSerialization.jsonObject`) so the caller
    /// can type-check the result.
    public static func decodeFramedJSON(_ framed: Data) throws -> Any? {
        guard framed.count >= 4 else { throw ClientError.malformedResponse }
        let length = framed.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
        let payload = framed.dropFirst(4)
        guard payload.count == Int(length) else { throw ClientError.malformedResponse }
        return try JSONSerialization.jsonObject(with: Data(payload))
    }

    /// Run the helper once. Nonblocking: the process-group runner's
    /// `terminationHandler` + continuation pattern never parks the
    /// cooperative thread pool, and the declared deadline bounds the wait.
    public static func run(_ request: Request) async throws -> Outcome {
        guard RendererAssetExtractorHelperLocation.isExecutableFile(request.helperURL) else {
            return Outcome(records: [], failureReason: "helper missing or invalid")
        }

        let framed: Data
        do {
            framed = try frameRequest(request)
        } catch {
            throw error
        }

        let groupRunnerRequest = RaceFreeProcessGroupRunner.Request(
            executableURL: request.helperURL,
            arguments: [],
            environment: [:],
            currentDirectoryURL: URL(fileURLWithPath: "/"),
            standardInput: framed,
            stdoutLimit: request.stdoutLimit,
            stderrLimit: request.stderrLimit)

        let handle: RaceFreeProcessGroupHandle
        do {
            handle = try RaceFreeProcessGroupRunner.launch(groupRunnerRequest)
        } catch {
            return Outcome(records: [], failureReason: "helper launch failed")
        }

        let result: ProcessGroupExecutionResult
        do {
            result = try await handle.result(timeout: .seconds(request.maxExecutionSeconds))
        } catch let error as RaceFreeProcessGroupError {
            // Timeout / output-limit: the runner already terminated and
            // reaped the verified group.
            switch error {
            case .timedOut:
                return Outcome(records: [], failureReason: "helper timed out")
            case .outputLimitExceeded:
                return Outcome(records: [], failureReason: "helper output exceeded limit")
            default:
                return Outcome(records: [], failureReason: "helper process failed")
            }
        } catch {
            return Outcome(records: [], failureReason: "helper process failed")
        }

        guard case .exited(let code) = result.terminationCause, code == 0 else {
            return Outcome(records: [], failureReason: "helper exited abnormally")
        }
        guard result.stdout.count <= request.stdoutLimit,
              result.stderr.count <= request.stderrLimit else {
            return Outcome(records: [], failureReason: "helper output exceeded limit")
        }
        // A decode failure is a malformed response, not a crash: we surface it
        // as a redacted fail-closed outcome. `try?` is intentional here.
        // swiftlint:disable:next silent_try_optional
        guard let response = try? Self.decodeFramedJSON(result.stdout) as? [String: Any] else {
            return Outcome(records: [], failureReason: "helper returned malformed JSON")
        }
        guard let ok = response["ok"] as? Bool else {
            return Outcome(records: [], failureReason: "helper returned no ok flag")
        }
        if ok == false {
            let reason = response["reason"] as? String
            return Outcome(records: [], failureReason: reason ?? "helper reported failure")
        }
        guard let records = response["records"] as? [[String: Any]] else {
            return Outcome(records: [], failureReason: "helper returned no records")
        }
        guard records.count <= request.maxReferenceCount else {
            return Outcome(records: [], failureReason: "helper returned too many records")
        }
        var validated: [ExtractedRecord] = []
        var seen = Set<String>()
        for record in records {
            guard let roleRaw = record["role"] as? String,
                  let role = RendererAssetRole(rawValue: roleRaw),
                  let reference = record["reference"] as? String,
                  reference.isEmpty == false,
                  reference.count <= 512 else {
                return Outcome(records: [], failureReason: "helper returned a malformed record")
            }
            let key = "\(roleRaw)\u{1f}\(reference)"
            guard seen.insert(key).inserted else {
                return Outcome(records: [], failureReason: "helper returned a duplicate record")
            }
            validated.append(ExtractedRecord(role: role, reference: reference))
        }
        return Outcome(records: validated, failureReason: nil)
    }
}

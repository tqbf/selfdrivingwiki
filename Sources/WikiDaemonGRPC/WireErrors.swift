#if os(macOS)
import Foundation
import GRPCCore
import GRPCProtobuf
import SwiftProtobuf
import WikiDaemonGRPCContract

/// The typed failure vocabulary of the app–daemon gRPC contract, mirrored
/// from `AppDaemonErrorDetails.Code` (the proto file is the source of truth;
/// the numeric values there are the compatibility contract).
///
/// Server handlers throw these; ``googleRPCStatus(instanceID:)`` converts to
/// a `GoogleRPCStatus` whose `grpc-status-details-bin` carries the versioned
/// `AppDaemonErrorDetails`. Clients convert failures back with
/// ``AppDaemonFailure/error(from:)``. This is the whole error mapping —
/// nothing maps through raw strings.
public struct AppDaemonFailure: Error, Equatable, Sendable {

    public enum Code: Equatable, Sendable, CaseIterable {
        case invalidRequest
        case unauthenticated
        case capabilityMismatch
        case resyncRequired
        case wikiNotFound
        case unavailable
        case resourceExhausted
        case deadlineExceeded

        var detailsCode: AppDaemonErrorDetails.Code {
            switch self {
            case .invalidRequest: .invalidRequest
            case .unauthenticated: .unauthenticated
            case .capabilityMismatch: .capabilityMismatch
            case .resyncRequired: .resyncRequired
            case .wikiNotFound: .wikiNotFound
            case .unavailable: .unavailable
            case .resourceExhausted: .resourceExhausted
            case .deadlineExceeded: .deadlineExceeded
            }
        }

        init?(detailsCode: AppDaemonErrorDetails.Code) {
            switch detailsCode {
            case .invalidRequest: self = .invalidRequest
            case .unauthenticated: self = .unauthenticated
            case .capabilityMismatch: self = .capabilityMismatch
            case .resyncRequired: self = .resyncRequired
            case .wikiNotFound: self = .wikiNotFound
            case .unavailable: self = .unavailable
            case .resourceExhausted: self = .resourceExhausted
            case .deadlineExceeded: self = .deadlineExceeded
            // Workload-family codes (step 2): no AppDaemonFailure.Code
            // equivalent yet. They surface as the conservative .unavailable
            // family when received; the mapping gains cases as the family
            // migration adds typed producers.
            case .storeOpenFailed, .storeSqlite, .pageNotFound,
                 .chatNotFound, .sourceNotFound, .sourceVersionNotFound,
                 .sourceMarkdownVersionNotFound, .noProcessedMarkdown,
                 .deletionRestricted, .invalidBookmarkRow,
                 .invalidRendererEventID, .storeUnexpected,
                 .duplicateContent, .duplicateURL, .pageConflict,
                 .pageCreateConflict, .pageExpectedTargetMissing,
                 .strategyRevisionConflict, .sourceMarkdownConflict,
                 .storeEpochMismatch, .outcomeUnknown,
                 .queueOwnershipTransition, .operationFailed,
                 .invalidEnvelope:
                return nil
            case .unspecified, .UNRECOGNIZED: return nil
            }
        }

        var grpcCode: RPCError.Code {
            switch self {
            case .invalidRequest: .invalidArgument
            case .unauthenticated: .unauthenticated
            case .capabilityMismatch: .failedPrecondition
            case .resyncRequired: .failedPrecondition
            case .wikiNotFound: .notFound
            case .unavailable: .unavailable
            case .resourceExhausted: .resourceExhausted
            case .deadlineExceeded: .deadlineExceeded
            }
        }

        var isRetryable: Bool {
            switch self {
            case .unavailable: true
            default: false
            }
        }
    }

    public let code: Code
    public let message: String
    public let retryable: Bool
    /// The daemon instance that produced the failure (server-side fill;
    /// client-side copy from decoded details when present).
    public let daemonInstanceID: String?

    public init(code: Code, message: String, retryable: Bool? = nil, daemonInstanceID: String? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable ?? code.isRetryable
        self.daemonInstanceID = daemonInstanceID
    }

    // MARK: Server side

    /// The current semantics version of AppDaemonErrorDetails (matches the
    /// proto comment: additive, non-breaking changes bump this).
    static let errorDetailsVersion: UInt32 = 1

    /// Convert to the throw-worthy rich status. The details ride in
    /// `grpc-status-details-bin`; the gRPC status code mirrors the failure
    /// family. The Any carries the message's fully-qualified proto name so
    /// both languages resolve it identically.
    public func googleRPCStatus(instanceID: String) -> GoogleRPCStatus {
        let details = AppDaemonErrorDetails.with {
            $0.version = Self.errorDetailsVersion
            $0.code = code.detailsCode
            $0.message = message
            $0.retryable = retryable
            $0.daemonInstanceID = instanceID
        }
        let packed: Google_Protobuf_Any
        do {
            packed = try Google_Protobuf_Any.with {
                $0.typeURL = "type.googleapis.com/\(AppDaemonErrorDetails.protoMessageName)"
                $0.value = try details.serializedBytes()
            }
        } catch {
            // Encoding of this fixed-shape value cannot fail in practice; if
            // it ever does, degrade to a bare status rather than a lie.
            return GoogleRPCStatus(code: code.grpcCode, message: message, details: [])
        }
        return GoogleRPCStatus(
            code: code.grpcCode,
            message: message,
            details: [.any(packed)])
    }

    // MARK: Client side

    /// Decode a received RPC failure into a typed failure. Checks the
    /// packed `AppDaemonErrorDetails` when present; falls back to a
    /// conservative mapping from the bare gRPC status code when the peer is
    /// older or the transport synthesized the error. An unknown details
    /// code maps to a conservative failure, never to a guessed family.
    public static func error(from rpcError: RPCError) -> AppDaemonFailure {
        // Undecodable details (older peer, transport-synthesized error)
        // fall through to the conservative bare-status mapping below —
        // that fallback IS the documented handling, so try? is the
        // intended control flow here.
        // swiftlint:disable:next silent_try_optional
        if let status = try? rpcError.unpackGoogleRPCStatus() {
            for detail in status.details {
                if let any = detail.any,
                   // A detail we cannot unpack (older/unknown type) is
                   // skipped; the loop continues to the conservative map.
                   // swiftlint:disable:next silent_try_optional
                   let decoded = try? AppDaemonErrorDetails(unpackingAny: any),
                   // A details VERSION this build does not understand is
                   // likewise skipped — its numeric codes mean nothing to us.
                   decoded.version == AppDaemonFailure.errorDetailsVersion,
                   let code = Code(detailsCode: decoded.code) {
                    return AppDaemonFailure(
                        code: code,
                        message: decoded.message.isEmpty ? rpcError.message : decoded.message,
                        retryable: decoded.retryable,
                        daemonInstanceID: decoded.daemonInstanceID.isEmpty
                            ? nil : decoded.daemonInstanceID)
                }
            }
        }
        return AppDaemonFailure(code: Self.fallbackCode(for: rpcError.code), message: rpcError.message)
    }

    private static func fallbackCode(for grpcCode: RPCError.Code) -> Code {
        switch grpcCode {
        case .unauthenticated: .unauthenticated
        case .invalidArgument: .invalidRequest
        case .notFound: .wikiNotFound
        case .resourceExhausted: .resourceExhausted
        case .deadlineExceeded: .deadlineExceeded
        case .failedPrecondition: .capabilityMismatch
        case .unavailable: .unavailable
        default: .unavailable
        }
    }
}
#endif

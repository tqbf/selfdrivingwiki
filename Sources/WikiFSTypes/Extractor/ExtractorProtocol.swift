import Foundation

// pattern: Functional Core

public struct ExtractorProtocolRequest: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case requestID, protocolRevision, kind, mimeType, originalFilename
        case inputTransport, inputPath, remoteURL, outputPath, deadlineMillisecondsSince1970
        case credentialFilePath, operationConfigurationPath
    }

    public let requestID: ExtractorRequestID
    public let protocolRevision: ExtractorProtocolRevision
    public let kind: ExtractorKind
    public let mimeType: ExtractorMIMEType
    public let originalFilename: String
    public let inputTransport: ExtractorInputTransport
    /// Mandatory for `.operationFile` input; always nil for `.remoteURL`.
    public let inputPath: ExtractorRelativePath?
    /// Mandatory for `.remoteURL` input; always nil for `.operationFile`.
    /// Protocol revision 3 only.
    public let remoteURL: ExtractorRemoteSourceURL?
    public let outputPath: ExtractorRelativePath
    public let deadlineMillisecondsSince1970: Int64
    /// Protocol revision 2 only: RELATIVE path (inside the private operation
    /// root) of the request-scoped credential input file. The request carries
    /// a path only — never a value. A revision 1 request must be nil.
    public let credentialFilePath: ExtractorRelativePath?
    /// Protocol revision 2 only: relative path of the non-secret public
    /// operation-configuration file (e.g. endpoint + timeout). Nil for
    /// revision 1.
    public let operationConfigurationPath: ExtractorRelativePath?

    /// The tagged operation input. `inputPath` is mandatory only for
    /// `.operationFile`; a `.remoteURL` request carries exactly one
    /// validated source URL and stages no bytes.
    public var operationInput: ExtractorOperationInput {
        if let remoteURL {
            return .remoteURL(remoteURL)
        }
        if let inputPath {
            return .operationFile(inputPath)
        }
        // Unreachable: the constructors reject an empty input.
        preconditionFailure("ExtractorProtocolRequest has no operation input")
    }

    /// The file-based (staged-bytes) request constructor. Every revision
    /// supports this transport.
    public init(
        requestID: ExtractorRequestID,
        protocolRevision: ExtractorProtocolRevision,
        kind: ExtractorKind,
        mimeType: ExtractorMIMEType,
        originalFilename: String,
        inputPath: ExtractorRelativePath,
        outputPath: ExtractorRelativePath,
        deadlineMillisecondsSince1970: Int64,
        credentialFilePath: ExtractorRelativePath? = nil,
        operationConfigurationPath: ExtractorRelativePath? = nil
    ) throws {
        try self.init(
            requestID: requestID,
            protocolRevision: protocolRevision,
            kind: kind,
            mimeType: mimeType,
            originalFilename: originalFilename,
            operationInput: .operationFile(inputPath),
            outputPath: outputPath,
            deadlineMillisecondsSince1970: deadlineMillisecondsSince1970,
            credentialFilePath: credentialFilePath,
            operationConfigurationPath: operationConfigurationPath)
    }

    /// The remote-URL request constructor (protocol revision 3). No input
    /// bytes exist; the package fetches the source itself.
    public init(
        requestID: ExtractorRequestID,
        protocolRevision: ExtractorProtocolRevision,
        kind: ExtractorKind,
        mimeType: ExtractorMIMEType,
        originalFilename: String,
        remoteURL: ExtractorRemoteSourceURL,
        outputPath: ExtractorRelativePath,
        deadlineMillisecondsSince1970: Int64,
        credentialFilePath: ExtractorRelativePath? = nil,
        operationConfigurationPath: ExtractorRelativePath? = nil
    ) throws {
        try self.init(
            requestID: requestID,
            protocolRevision: protocolRevision,
            kind: kind,
            mimeType: mimeType,
            originalFilename: originalFilename,
            operationInput: .remoteURL(remoteURL),
            outputPath: outputPath,
            deadlineMillisecondsSince1970: deadlineMillisecondsSince1970,
            credentialFilePath: credentialFilePath,
            operationConfigurationPath: operationConfigurationPath)
    }

    private init(
        requestID: ExtractorRequestID,
        protocolRevision: ExtractorProtocolRevision,
        kind: ExtractorKind,
        mimeType: ExtractorMIMEType,
        originalFilename: String,
        operationInput: ExtractorOperationInput,
        outputPath: ExtractorRelativePath,
        deadlineMillisecondsSince1970: Int64,
        credentialFilePath: ExtractorRelativePath?,
        operationConfigurationPath: ExtractorRelativePath?
    ) throws {
        guard originalFilename.isEmpty == false,
              originalFilename.utf8.count <= 1_024,
              originalFilename.contains("\0") == false else {
            throw ExtractorValidationError.invalidManifest("original filename")
        }
        // A revision 1 request can neither declare nor receive credentials:
        // operation input paths must be absent.
        if protocolRevision == .v1,
           credentialFilePath != nil || operationConfigurationPath != nil {
            throw ExtractorValidationError.invalidManifest(
                "credential input requires protocol revision 2")
        }
        // The remote-url transport is a revision-3 feature. Revisions 1 and
        // 2 keep their exact old wire contract.
        if protocolRevision.rawValue < 3,
           case .remoteURL = operationInput {
            throw ExtractorValidationError.invalidManifest(
                "remote-url input requires protocol revision 3")
        }
        if case .operationFile(let inputPath) = operationInput {
            guard inputPath != outputPath else {
                throw ExtractorValidationError.invalidManifest("input and output paths match")
            }
        }
        guard deadlineMillisecondsSince1970 > 0 else { throw ExtractorValidationError.invalidManifest("deadline") }
        self.requestID = requestID
        self.protocolRevision = protocolRevision
        self.kind = kind
        self.mimeType = mimeType
        self.originalFilename = originalFilename
        self.inputTransport = operationInput.transport
        switch operationInput {
        case .operationFile(let path):
            self.inputPath = path
            self.remoteURL = nil
        case .remoteURL(let url):
            self.inputPath = nil
            self.remoteURL = url
        }
        self.outputPath = outputPath
        self.deadlineMillisecondsSince1970 = deadlineMillisecondsSince1970
        self.credentialFilePath = credentialFilePath
        self.operationConfigurationPath = operationConfigurationPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try container.decode(
            ExtractorProtocolRevision.self, forKey: .protocolRevision)
        // Revision 1 requests must not carry operation input paths: a v1
        // package can neither declare nor receive credentials.
        if revision == .v1,
           container.contains(.credentialFilePath)
               || container.contains(.operationConfigurationPath) {
            throw ExtractorValidationError.invalidManifest(
                "credential input requires protocol revision 2")
        }
        // Decode the input transport explicitly, then enforce the revision's
        // exact wire shape. `remoteURL` is rejected wherever it may not
        // appear, so old revisions never silently ignore a revision-3 key
        // and no revision accepts a mixed shape.
        let transport = try container.decode(
            ExtractorInputTransport.self, forKey: .inputTransport)
        let input: ExtractorOperationInput
        switch transport {
        case .operationFile:
            guard container.contains(.remoteURL) == false else {
                throw ExtractorValidationError.invalidManifest(
                    "operation-file input cannot carry remoteURL")
            }
            input = .operationFile(try container.decode(
                ExtractorRelativePath.self, forKey: .inputPath))
        case .remoteURL:
            guard revision == .v3 else {
                throw ExtractorValidationError.invalidManifest(
                    "remote-url input requires protocol revision 3")
            }
            guard container.contains(.inputPath) == false else {
                throw ExtractorValidationError.invalidManifest(
                    "remote-url input cannot carry inputPath")
            }
            input = .remoteURL(try container.decode(
                ExtractorRemoteSourceURL.self, forKey: .remoteURL))
        }
        try self.init(
            requestID: container.decode(ExtractorRequestID.self, forKey: .requestID),
            protocolRevision: revision,
            kind: container.decode(ExtractorKind.self, forKey: .kind),
            mimeType: container.decode(ExtractorMIMEType.self, forKey: .mimeType),
            originalFilename: container.decode(String.self, forKey: .originalFilename),
            operationInput: input,
            outputPath: container.decode(ExtractorRelativePath.self, forKey: .outputPath),
            deadlineMillisecondsSince1970: container.decode(Int64.self, forKey: .deadlineMillisecondsSince1970),
            credentialFilePath: container.decodeIfPresent(
                ExtractorRelativePath.self, forKey: .credentialFilePath),
            operationConfigurationPath: container.decodeIfPresent(
                ExtractorRelativePath.self, forKey: .operationConfigurationPath))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(protocolRevision, forKey: .protocolRevision)
        try container.encode(kind, forKey: .kind)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(originalFilename, forKey: .originalFilename)
        try container.encode(inputTransport, forKey: .inputTransport)
        switch operationInput {
        case .operationFile(let path):
            try container.encode(path, forKey: .inputPath)
        case .remoteURL(let url):
            try container.encode(url, forKey: .remoteURL)
        }
        try container.encode(outputPath, forKey: .outputPath)
        try container.encode(deadlineMillisecondsSince1970, forKey: .deadlineMillisecondsSince1970)
        if let credentialFilePath {
            try container.encode(credentialFilePath, forKey: .credentialFilePath)
        }
        if let operationConfigurationPath {
            try container.encode(operationConfigurationPath, forKey: .operationConfigurationPath)
        }
    }
}

// MARK: - Operation input transports (protocol revision 3)

/// The tagged operation input of one extractor request: staged operation
/// bytes (`operation-file`, every revision) or one validated remote source
/// URL (`remote-url`, revision 3). The tag and its payload are mutually
/// exclusive by construction.
public enum ExtractorOperationInput: Hashable, Sendable {
    case operationFile(ExtractorRelativePath)
    case remoteURL(ExtractorRemoteSourceURL)

    public var transport: ExtractorInputTransport {
        switch self {
        case .operationFile: .operationFile
        case .remoteURL: .remoteURL
        }
    }
}

/// One normalized HTTP or HTTPS source URL carried by a `remote-url`
/// request. Validation happens at construction, before the host ever spawns
/// a package process: other schemes (`file:`, `data:`, ftp:), embedded
/// credentials, fragments, missing hosts, NUL bytes, and over-limit strings
/// are all rejected. The stored value is normalized — lowercase scheme and
/// host, no default port — so one source has exactly one wire identity.
public struct ExtractorRemoteSourceURL: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Bounded like every other host-supplied request string; matches the
    /// operation-configuration endpoint bound.
    public static let maximumByteCount = 2_048

    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.isEmpty == false,
              rawValue.utf8.count <= Self.maximumByteCount,
              rawValue.contains("\0") == false,
              let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              host.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { return nil }
        var normalized = components
        normalized.scheme = scheme
        normalized.host = host.lowercased()
        if normalized.port == (scheme == "https" ? 443 : 80) {
            normalized.port = nil
        }
        guard let value = normalized.string else { return nil }
        self.rawValue = value
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw ExtractorValidationError.invalidIdentifier(
                kind: "extractor remote source URL", value: rawValue)
        }
        self = value
    }

    /// The parsed URL. Construction already validated it, so this is
    /// non-optional for every stored value.
    public var url: URL {
        guard let url = URL(string: rawValue) else {
            preconditionFailure("validated remote source URL re-parses: \(rawValue)")
        }
        return url
    }

    public init(from decoder: any Decoder) throws { try self.init(validating: String(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var description: String { rawValue }
}

// MARK: - Operation input envelopes (protocol revision 2)

/// The PRIVATE credential input envelope written to the request-scoped
/// credential file. Keyed by requirement ID; carries only the selected
/// registration's resolved NON-EMPTY values. Values live in this file for the
/// duration of one request and are deleted on every terminal path.
public struct ExtractorCredentialInputEnvelope: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case credentials }

    public static let maximumEntryCount = 8

    /// Requirement-ID raw values -> resolved secret values.
    public let credentials: [String: String]

    /// Host-owned construction: entries must be declared requirement IDs and
    /// non-empty values. There is no public memberwise initializer, so a
    /// caller cannot smuggle arbitrary key/value pairs past validation.
    public init(
        requirements: [ExtractorCredentialRequirement],
        resolvedValues: [ExtractorCredentialRequirementID: String]
    ) throws {
        guard resolvedValues.count <= Self.maximumEntryCount else {
            throw ExtractorValidationError.invalidManifest("credential envelope size")
        }
        var encoded: [String: String] = [:]
        for requirement in requirements {
            guard let value = resolvedValues[requirement.id] else { continue }
            guard CredentialValue.normalized(value) != nil else { continue }
            encoded[requirement.id.rawValue] = value
        }
        self.credentials = encoded
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.credentials = try container.decode([String: String].self, forKey: .credentials)
    }
}

/// The PUBLIC, non-secret operation-configuration envelope (protocol
/// revision 2+). A closed tagged model: one case per supported configuration
/// family, and the case tag is the construction seam — a Docling endpoint
/// cannot carry a helper path and an Apple helper grant cannot carry an
/// endpoint, so a secret or an arbitrary path cannot be encoded even by
/// mistake. Values arrive from typed host settings.
///
/// Wire shapes:
/// - `.doclingServe` encodes the legacy flat shape
///   (`{"endpoint": …, "timeoutMilliseconds": …}`) because the installed
///   reviewed Docling Serve protocol-v2 package reads exactly that shape.
/// - `.applePodcastTranscript` encodes the tagged shape
///   (`{"kind": "apple-podcast-transcript", "helperPath": …}`). The path is
///   RELATIVE to the operation root and names a host-staged, owner-private
///   executable (see the engine's operation-support staging); it is not a
///   secret and is never an absolute path.
public enum ExtractorOperationConfiguration: Hashable, Sendable {
    /// The Docling Serve endpoint + timeout. Both fields optional; the
    /// package reports a clear setup failure when its endpoint is missing.
    case doclingServe(endpoint: String?, timeoutMilliseconds: Int?)
    /// The reviewed Apple package's staged helper grant: the helper's
    /// relative path inside the operation root. No absolute path, no
    /// argument, no endpoint — the package resolves it against its own
    /// operation root.
    case applePodcastTranscript(helperPath: ExtractorRelativePath)

    public static let maximumEndpointByteCount = 2_048
    public static let maximumTimeoutMilliseconds = ExtractorHostLimits.maximumDurationMilliseconds
    static let appleKindValue = "apple-podcast-transcript"

    /// The legacy-compatible Docling construction. Validation matches the
    /// original struct: bounded http/https endpoint, in-policy timeout.
    public init(endpoint: String?, timeoutMilliseconds: Int?) throws {
        if let endpoint {
            guard endpoint.isEmpty == false,
                  endpoint.utf8.count <= Self.maximumEndpointByteCount,
                  endpoint.contains("\0") == false else {
                throw ExtractorValidationError.invalidManifest("operation endpoint")
            }
            // Only http/https endpoints are valid targets (security review
            // HIGH-2): other schemes (file:, data:, ftp:) must never reach a
            // package's request builder.
            guard let url = URL(string: endpoint),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else {
                throw ExtractorValidationError.invalidManifest("operation endpoint scheme")
            }
        }
        if let timeoutMilliseconds {
            guard timeoutMilliseconds > 0,
                  timeoutMilliseconds <= Self.maximumTimeoutMilliseconds else {
                throw ExtractorValidationError.limitExceedsHostPolicy("operation timeout")
            }
        }
        self = .doclingServe(endpoint: endpoint, timeoutMilliseconds: timeoutMilliseconds)
    }
}

extension ExtractorOperationConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, endpoint, timeoutMilliseconds, helperPath
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .doclingServe(let endpoint, let timeoutMilliseconds):
            // Legacy flat shape — the installed reviewed Docling Serve
            // package decodes exactly these two keys.
            if let endpoint { try container.encode(endpoint, forKey: .endpoint) }
            if let timeoutMilliseconds {
                try container.encode(timeoutMilliseconds, forKey: .timeoutMilliseconds)
            }
        case .applePodcastTranscript(let helperPath):
            try container.encode(Self.appleKindValue, forKey: .kind)
            try container.encode(helperPath, forKey: .helperPath)
        }
    }

    public init(from decoder: any Decoder) throws {
        // Decode through a raw key/value map so UNKNOWN fields are rejected
        // instead of silently ignored, and mixed-shape documents fail closed.
        let raw = try [String: ExtractorConfigurationWireValue](from: decoder)
        for key in raw.keys where CodingKeys(rawValue: key) == nil {
            throw ExtractorValidationError.invalidManifest(
                "unknown operation configuration field")
        }
        switch raw[CodingKeys.kind.rawValue]?.stringValue {
        case nil:
            // Legacy flat shape (Docling). A helper path or a known field with
            // an invalid value type makes the shape invalid.
            guard raw[CodingKeys.helperPath.rawValue] == nil else {
                throw ExtractorValidationError.invalidManifest(
                    "invalid legacy operation configuration")
            }
            if let endpointValue = raw[CodingKeys.endpoint.rawValue],
               case .string = endpointValue {} else if raw[CodingKeys.endpoint.rawValue] != nil {
                throw ExtractorValidationError.invalidManifest(
                    "invalid legacy operation configuration endpoint")
            }
            if let timeoutValue = raw[CodingKeys.timeoutMilliseconds.rawValue],
               case .number = timeoutValue {} else if raw[CodingKeys.timeoutMilliseconds.rawValue] != nil {
                throw ExtractorValidationError.invalidManifest(
                    "invalid legacy operation configuration timeout")
            }
            let endpoint = raw[CodingKeys.endpoint.rawValue]?.stringValue
            let timeout = raw[CodingKeys.timeoutMilliseconds.rawValue]?.intValue
            try self.init(endpoint: endpoint, timeoutMilliseconds: timeout)
        case Self.appleKindValue:
            // Tagged Apple shape: helper path required; Docling fields must
            // be absent.
            guard raw[CodingKeys.endpoint.rawValue] == nil,
                  raw[CodingKeys.timeoutMilliseconds.rawValue] == nil else {
                throw ExtractorValidationError.invalidManifest(
                    "apple-podcast-transcript configuration accepts a helper path only")
            }
            guard let helperRaw = raw[CodingKeys.helperPath.rawValue]?.stringValue,
                let helperPath = ExtractorRelativePath(rawValue: helperRaw) else {
                throw ExtractorValidationError.invalidManifest(
                    "apple-podcast-transcript helper path")
            }
            self = .applePodcastTranscript(helperPath: helperPath)
        case .some:
            throw ExtractorValidationError.invalidManifest(
                "unknown operation configuration kind")
        }
    }
}

/// Raw JSON value probe for closed-envelope decoding. Only the shapes the
/// operation-configuration envelope reads are distinguished; every other
/// JSON shape fails the field probe and the envelope rejects the document.
public enum ExtractorConfigurationWireValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Int)
    case other

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Field probing is the closed-envelope decode strategy: a value that
        // matches no readable shape falls through to `.other` and the
        // envelope rejects the document.
        // swiftlint:disable:next silent_try_optional
        if let value = try? container.decode(String.self) {
            self = .string(value)
        // swiftlint:disable:next silent_try_optional
        } else if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .other
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .other: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return value }
        return nil
    }
}

public struct ExtractorPackageExecutionProvenance: Codable, Hashable, Sendable {
    public let revision: ExtractorPackageRevisionID
    public var packageID: String { revision.packageID.rawValue }
    public var version: String { revision.version.rawValue }
    public var digest: String { revision.digest.hex }
    public let registrationID: ExtractorRegistrationID
    public let protocolRevision: ExtractorProtocolRevision
    public let reportedMetadata: ExtractorReportedMetadata

    public init(
        revision: ExtractorPackageRevisionID,
        registrationID: ExtractorRegistrationID,
        protocolRevision: ExtractorProtocolRevision,
        reportedMetadata: ExtractorReportedMetadata = .empty
    ) {
        self.revision = revision
        self.registrationID = registrationID
        self.protocolRevision = protocolRevision
        self.reportedMetadata = reportedMetadata
    }
}

public struct ExtractorReportedMetadata: Codable, Hashable, Sendable {
    public static let empty = ExtractorReportedMetadata(
        validatedToolName: nil,
        toolVersion: nil,
        modelName: nil,
        modelVersion: nil,
        language: nil,
        transcriptGenerated: nil)

    public let toolName: String?
    public let toolVersion: String?
    public let modelName: String?
    public let modelVersion: String?
    /// The caption language a transcript package selected, when it can
    /// report one. Optional and additive: packages and hosts that never
    /// write it keep decoding byte-for-byte.
    public let language: String?
    /// Whether the selected captions were auto-generated, when the package
    /// can report it. Optional and additive like `language`.
    public let transcriptGenerated: Bool?

    public init(
        toolName: String? = nil,
        toolVersion: String? = nil,
        modelName: String? = nil,
        modelVersion: String? = nil,
        language: String? = nil,
        transcriptGenerated: Bool? = nil
    ) throws {
        for value in [toolName, toolVersion, modelName, modelVersion, language].compactMap({ $0 }) {
            guard value.isEmpty == false, value.utf8.count <= 256, value.contains("\0") == false else {
                throw ExtractorValidationError.invalidManifest("reported metadata")
            }
        }
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.language = language
        self.transcriptGenerated = transcriptGenerated
    }

    private init(
        validatedToolName: String?,
        toolVersion: String?,
        modelName: String?,
        modelVersion: String?,
        language: String?,
        transcriptGenerated: Bool?
    ) {
        self.toolName = validatedToolName
        self.toolVersion = toolVersion
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.language = language
        self.transcriptGenerated = transcriptGenerated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            toolName: container.decodeIfPresent(String.self, forKey: .toolName),
            toolVersion: container.decodeIfPresent(String.self, forKey: .toolVersion),
            modelName: container.decodeIfPresent(String.self, forKey: .modelName),
            modelVersion: container.decodeIfPresent(String.self, forKey: .modelVersion),
            language: container.decodeIfPresent(String.self, forKey: .language),
            transcriptGenerated: container.decodeIfPresent(Bool.self, forKey: .transcriptGenerated))
    }
}

public struct ExtractorProgressFrame: Codable, Hashable, Sendable {
    public let requestID: ExtractorRequestID
    public let completedUnitCount: Int?
    public let totalUnitCount: Int?
    public let message: String?

    public init(requestID: ExtractorRequestID, completedUnitCount: Int? = nil, totalUnitCount: Int? = nil, message: String? = nil) throws {
        let completedIsValid = completedUnitCount.map { $0 >= 0 } ?? true
        let totalIsValid = totalUnitCount.map { $0 > 0 } ?? true
        let countPairIsValid = completedUnitCount.flatMap { completed in
            totalUnitCount.map { completed <= $0 }
        } ?? true
        let messageIsValid = message.map {
            $0.isEmpty == false && $0.utf8.count <= 1_024 && $0.contains("\0") == false
        } ?? true
        guard completedIsValid, totalIsValid, countPairIsValid, messageIsValid else {
            throw ExtractorValidationError.invalidManifest("progress frame")
        }
        self.requestID = requestID
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(ExtractorRequestID.self, forKey: .requestID),
            completedUnitCount: container.decodeIfPresent(Int.self, forKey: .completedUnitCount),
            totalUnitCount: container.decodeIfPresent(Int.self, forKey: .totalUnitCount),
            message: container.decodeIfPresent(String.self, forKey: .message))
    }
}

public struct ExtractorDiagnosticFrame: Codable, Hashable, Sendable {
    public let requestID: ExtractorRequestID
    public let message: String

    public init(requestID: ExtractorRequestID, message: String) throws {
        guard message.isEmpty == false, message.utf8.count <= 4_096, message.contains("\0") == false else {
            throw ExtractorValidationError.invalidManifest("diagnostic frame")
        }
        self.requestID = requestID
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestID: container.decode(ExtractorRequestID.self, forKey: .requestID), message: container.decode(String.self, forKey: .message))
    }
}

/// Optional article facts a package may report beside its Markdown result.
/// All fields are optional and individually validated; HTML packages use these
/// to preserve Defuddle-style article metadata end to end.
public struct ExtractorArticleMetadata: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case title, author, description, published, wordCount
    }

    static let maximumTextByteCount = 1_024
    static let maximumWordCount = 10_000_000

    public let title: String?
    public let author: String?
    public let description: String?
    public let published: String?
    public let wordCount: Int?

    public init(
        title: String? = nil,
        author: String? = nil,
        description: String? = nil,
        published: String? = nil,
        wordCount: Int? = nil
    ) throws {
        for value in [title, author, description, published].compactMap({ $0 }) {
            guard value.isEmpty == false,
                  value.utf8.count <= Self.maximumTextByteCount,
                  value.contains("\0") == false else {
                throw ExtractorValidationError.invalidManifest("article metadata")
            }
        }
        guard wordCount.map({ $0 >= 0 && $0 <= Self.maximumWordCount }) ?? true else {
            throw ExtractorValidationError.invalidManifest("article metadata")
        }
        self.title = title
        self.author = author
        self.description = description
        self.published = published
        self.wordCount = wordCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: try Self.optionalString(container, .title),
            author: try Self.optionalString(container, .author),
            description: try Self.optionalString(container, .description),
            published: try Self.optionalString(container, .published),
            wordCount: try container.decodeIfPresent(Int.self, forKey: .wordCount))
    }

    private static func optionalString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        return try container.decode(String.self, forKey: key)
    }
}

public struct ExtractorResultFrame: Codable, Hashable, Sendable {
    public let requestID: ExtractorRequestID
    public let outputPath: ExtractorRelativePath
    public let markdownByteCount: Int
    public let warnings: [String]
    public let metadata: ExtractorReportedMetadata
    public let articleMetadata: ExtractorArticleMetadata?

    private enum CodingKeys: String, CodingKey {
        case requestID, outputPath, markdownByteCount, warnings, metadata
        case articleMetadata
    }

    public init(
        requestID: ExtractorRequestID,
        outputPath: ExtractorRelativePath,
        markdownByteCount: Int,
        warnings: [String] = [],
        metadata: ExtractorReportedMetadata = .empty,
        articleMetadata: ExtractorArticleMetadata? = nil
    ) throws {
        guard markdownByteCount >= 0, markdownByteCount <= ExtractorHostLimits.maximumMarkdownOutputByteCount,
              warnings.count <= 128,
              warnings.allSatisfy({ $0.isEmpty == false && $0.utf8.count <= 1_024 && $0.contains("\0") == false }) else {
            throw ExtractorValidationError.invalidManifest("result frame")
        }
        self.requestID = requestID
        self.outputPath = outputPath
        self.markdownByteCount = markdownByteCount
        self.warnings = warnings
        self.metadata = metadata
        self.articleMetadata = articleMetadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(ExtractorRequestID.self, forKey: .requestID),
            outputPath: container.decode(ExtractorRelativePath.self, forKey: .outputPath),
            markdownByteCount: container.decode(Int.self, forKey: .markdownByteCount),
            warnings: container.decodeIfPresent([String].self, forKey: .warnings) ?? [],
            metadata: container.decodeIfPresent(ExtractorReportedMetadata.self, forKey: .metadata) ?? ExtractorReportedMetadata(),
            articleMetadata: try container.decodeIfPresent(
                ExtractorArticleMetadata.self,
                forKey: .articleMetadata))
    }
}

public struct ExtractorFailureFrame: Codable, Hashable, Sendable {
    public let requestID: ExtractorRequestID
    public let cause: ExtractorFailureCause
    public let message: String
    public let warnings: [String]
    public let metadata: ExtractorReportedMetadata

    public init(
        requestID: ExtractorRequestID,
        cause: ExtractorFailureCause,
        message: String,
        warnings: [String] = [],
        metadata: ExtractorReportedMetadata = .empty
    ) throws {
        guard message.isEmpty == false, message.utf8.count <= 4_096, message.contains("\0") == false,
              warnings.count <= 128,
              warnings.allSatisfy({ $0.isEmpty == false && $0.utf8.count <= 1_024 && $0.contains("\0") == false }) else {
            throw ExtractorValidationError.invalidManifest("failure frame")
        }
        self.requestID = requestID
        self.cause = cause
        self.message = message
        self.warnings = warnings
        self.metadata = metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(ExtractorRequestID.self, forKey: .requestID),
            cause: container.decode(ExtractorFailureCause.self, forKey: .cause),
            message: container.decode(String.self, forKey: .message),
            warnings: container.decodeIfPresent([String].self, forKey: .warnings) ?? [],
            metadata: container.decodeIfPresent(ExtractorReportedMetadata.self, forKey: .metadata) ?? ExtractorReportedMetadata())
    }
}

public enum ExtractorProtocolFrame: Codable, Hashable, Sendable {
    case progress(ExtractorProgressFrame)
    case diagnostic(ExtractorDiagnosticFrame)
    case result(ExtractorResultFrame)
    case failure(ExtractorFailureFrame)

    private enum CodingKeys: String, CodingKey { case kind, payload }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ExtractorEventKind.self, forKey: .kind) {
        case .progress: self = .progress(try container.decode(ExtractorProgressFrame.self, forKey: .payload))
        case .diagnostic: self = .diagnostic(try container.decode(ExtractorDiagnosticFrame.self, forKey: .payload))
        case .result: self = .result(try container.decode(ExtractorResultFrame.self, forKey: .payload))
        case .failure: self = .failure(try container.decode(ExtractorFailureFrame.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .progress(let frame): try container.encode(ExtractorEventKind.progress, forKey: .kind); try container.encode(frame, forKey: .payload)
        case .diagnostic(let frame): try container.encode(ExtractorEventKind.diagnostic, forKey: .kind); try container.encode(frame, forKey: .payload)
        case .result(let frame): try container.encode(ExtractorEventKind.result, forKey: .kind); try container.encode(frame, forKey: .payload)
        case .failure(let frame): try container.encode(ExtractorEventKind.failure, forKey: .kind); try container.encode(frame, forKey: .payload)
        }
    }

    public var requestID: ExtractorRequestID {
        switch self {
        case .progress(let frame): frame.requestID
        case .diagnostic(let frame): frame.requestID
        case .result(let frame): frame.requestID
        case .failure(let frame): frame.requestID
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .result, .failure: true
        case .progress, .diagnostic: false
        }
    }
}

public enum ExtractorProtocolSequenceError: Error, Equatable, Sendable {
    case requestMismatch
    case outputPathMismatch
    case tooManyProgressEvents
    case duplicateTerminal
    case outputAfterTerminal
    case missingTerminal
}

/// Pure revision-1 frame-sequence validator. Byte and UTF-8 bounds belong to the stream decoder.
public struct ExtractorProtocolSequence: Sendable {
    public let requestID: ExtractorRequestID
    public let expectedOutputPath: ExtractorRelativePath
    public let maximumProgressEventCount: Int
    private(set) public var progressEventCount = 0
    private(set) public var terminalFrame: ExtractorProtocolFrame?

    public init(
        requestID: ExtractorRequestID,
        expectedOutputPath: ExtractorRelativePath,
        maximumProgressEventCount: Int
    ) {
        self.requestID = requestID
        self.expectedOutputPath = expectedOutputPath
        self.maximumProgressEventCount = maximumProgressEventCount
    }

    public mutating func consume(_ frame: ExtractorProtocolFrame) throws {
        guard frame.requestID == requestID else { throw ExtractorProtocolSequenceError.requestMismatch }
        guard terminalFrame == nil else {
            throw frame.isTerminal ? ExtractorProtocolSequenceError.duplicateTerminal : ExtractorProtocolSequenceError.outputAfterTerminal
        }
        switch frame {
        case .progress:
            progressEventCount += 1
            guard progressEventCount <= maximumProgressEventCount else {
                throw ExtractorProtocolSequenceError.tooManyProgressEvents
            }
        case .diagnostic:
            break
        case .result(let result):
            guard result.outputPath == expectedOutputPath else {
                throw ExtractorProtocolSequenceError.outputPathMismatch
            }
            terminalFrame = frame
        case .failure:
            terminalFrame = frame
        }
    }

    public func finish() throws -> ExtractorProtocolFrame {
        guard let terminalFrame else { throw ExtractorProtocolSequenceError.missingTerminal }
        return terminalFrame
    }
}

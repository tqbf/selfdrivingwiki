import Foundation

// pattern: Functional Core

public struct ExtractorProtocolRequest: Codable, Hashable, Sendable {
    public let requestID: ExtractorRequestID
    public let protocolRevision: ExtractorProtocolRevision
    public let kind: ExtractorKind
    public let mimeType: ExtractorMIMEType
    public let originalFilename: String
    public let inputTransport: ExtractorInputTransport
    public let inputPath: ExtractorRelativePath
    public let outputPath: ExtractorRelativePath
    public let deadlineMillisecondsSince1970: Int64

    public init(
        requestID: ExtractorRequestID,
        protocolRevision: ExtractorProtocolRevision,
        kind: ExtractorKind,
        mimeType: ExtractorMIMEType,
        originalFilename: String,
        inputTransport: ExtractorInputTransport = .operationFile,
        inputPath: ExtractorRelativePath,
        outputPath: ExtractorRelativePath,
        deadlineMillisecondsSince1970: Int64
    ) throws {
        guard originalFilename.isEmpty == false,
              originalFilename.utf8.count <= 1_024,
              originalFilename.contains("\0") == false else {
            throw ExtractorValidationError.invalidManifest("original filename")
        }
        guard inputPath != outputPath else { throw ExtractorValidationError.invalidManifest("input and output paths match") }
        guard deadlineMillisecondsSince1970 > 0 else { throw ExtractorValidationError.invalidManifest("deadline") }
        self.requestID = requestID
        self.protocolRevision = protocolRevision
        self.kind = kind
        self.mimeType = mimeType
        self.originalFilename = originalFilename
        self.inputTransport = inputTransport
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.deadlineMillisecondsSince1970 = deadlineMillisecondsSince1970
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(ExtractorRequestID.self, forKey: .requestID),
            protocolRevision: container.decode(ExtractorProtocolRevision.self, forKey: .protocolRevision),
            kind: container.decode(ExtractorKind.self, forKey: .kind),
            mimeType: container.decode(ExtractorMIMEType.self, forKey: .mimeType),
            originalFilename: container.decode(String.self, forKey: .originalFilename),
            inputTransport: container.decode(ExtractorInputTransport.self, forKey: .inputTransport),
            inputPath: container.decode(ExtractorRelativePath.self, forKey: .inputPath),
            outputPath: container.decode(ExtractorRelativePath.self, forKey: .outputPath),
            deadlineMillisecondsSince1970: container.decode(Int64.self, forKey: .deadlineMillisecondsSince1970))
    }
}

public struct ExtractorReportedMetadata: Codable, Hashable, Sendable {
    public static let empty = ExtractorReportedMetadata(
        validatedToolName: nil,
        toolVersion: nil,
        modelName: nil,
        modelVersion: nil)

    public let toolName: String?
    public let toolVersion: String?
    public let modelName: String?
    public let modelVersion: String?

    public init(toolName: String? = nil, toolVersion: String? = nil, modelName: String? = nil, modelVersion: String? = nil) throws {
        for value in [toolName, toolVersion, modelName, modelVersion].compactMap({ $0 }) {
            guard value.isEmpty == false, value.utf8.count <= 256, value.contains("\0") == false else {
                throw ExtractorValidationError.invalidManifest("reported metadata")
            }
        }
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.modelName = modelName
        self.modelVersion = modelVersion
    }

    private init(validatedToolName: String?, toolVersion: String?, modelName: String?, modelVersion: String?) {
        self.toolName = validatedToolName
        self.toolVersion = toolVersion
        self.modelName = modelName
        self.modelVersion = modelVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            toolName: container.decodeIfPresent(String.self, forKey: .toolName),
            toolVersion: container.decodeIfPresent(String.self, forKey: .toolVersion),
            modelName: container.decodeIfPresent(String.self, forKey: .modelName),
            modelVersion: container.decodeIfPresent(String.self, forKey: .modelVersion))
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

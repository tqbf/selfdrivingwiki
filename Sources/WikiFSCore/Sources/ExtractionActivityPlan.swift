import Foundation

// pattern: Functional Core

/// The durable, versioned details of an extraction activity. The normalized
/// markdown and agent columns remain the compatibility fallback for old or
/// malformed plan JSON.
public struct ExtractionActivityPlan: Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let producer: ExtractionProducer?
    public let origin: SourceMarkdownOrigin
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let toolVersion: String?
    public let sourceVersionID: SourceVersionID?
    public let note: String?

    public init(
        version: Int = Self.currentVersion,
        producer: ExtractionProducer?,
        origin: SourceMarkdownOrigin,
        providerID: ProviderID? = nil,
        modelID: ModelID? = nil,
        toolVersion: String? = nil,
        sourceVersionID: SourceVersionID? = nil,
        note: String? = nil
    ) {
        self.version = version
        self.producer = producer
        self.origin = origin
        self.providerID = providerID
        self.modelID = modelID
        self.toolVersion = toolVersion
        self.sourceVersionID = sourceVersionID
        self.note = note
    }
}

public enum ExtractionPlanCodecError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case malformedJSON
}

/// Encodes only the current plan shape and decodes both that shape and the
/// pre-versioned `{ backend, model }` plan written by older extraction rows.
public enum ExtractionActivityPlanCodec {
    private struct CurrentPlan: Codable {
        let version: Int
        let producer: Producer?
        let origin: SourceMarkdownOrigin
        let providerID: ProviderID?
        let modelID: ModelID?
        let toolVersion: String?
        let sourceVersionID: SourceVersionID?
        let note: String?
    }

    private enum Producer: Codable {
        case backend(ExtractionBackend)
        case tool(ExtractionTool)
        case legacy(rawTechnique: String?)

        private enum CodingKeys: String, CodingKey { case kind, backend, tool, rawTechnique }
        private enum Kind: String, Codable { case backend, tool, legacy }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .backend: self = .backend(try container.decode(ExtractionBackend.self, forKey: .backend))
            case .tool: self = .tool(try container.decode(ExtractionTool.self, forKey: .tool))
            case .legacy: self = .legacy(rawTechnique: try container.decodeIfPresent(String.self, forKey: .rawTechnique))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .backend(let backend):
                try container.encode(Kind.backend, forKey: .kind)
                try container.encode(backend, forKey: .backend)
            case .tool(let tool):
                try container.encode(Kind.tool, forKey: .kind)
                try container.encode(tool, forKey: .tool)
            case .legacy(let rawTechnique):
                try container.encode(Kind.legacy, forKey: .kind)
                try container.encodeIfPresent(rawTechnique, forKey: .rawTechnique)
            }
        }

        init(_ producer: ExtractionProducer) {
            switch producer {
            case .backend(let backend): self = .backend(backend)
            case .tool(let tool): self = .tool(tool)
            case .legacy(let rawTechnique): self = .legacy(rawTechnique: rawTechnique)
            }
        }

        var value: ExtractionProducer {
            switch self {
            case .backend(let backend): return .backend(backend)
            case .tool(let tool): return .tool(tool)
            case .legacy(let rawTechnique): return .legacy(rawTechnique: rawTechnique)
            }
        }
    }

    private struct LegacyPlan: Decodable {
        let backend: ExtractionBackend
        let model: ModelID?
    }

    public static func encode(_ plan: ExtractionActivityPlan) throws -> String {
        let current = CurrentPlan(
            version: plan.version, producer: plan.producer.map(Producer.init), origin: plan.origin,
            providerID: plan.providerID, modelID: plan.modelID, toolVersion: plan.toolVersion,
            sourceVersionID: plan.sourceVersionID, note: plan.note)
        let data = try JSONEncoder().encode(current)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) throws -> ExtractionActivityPlan {
        let data = Data(json.utf8)
        do {
            let current = try JSONDecoder().decode(CurrentPlan.self, from: data)
            guard current.version == ExtractionActivityPlan.currentVersion else {
                throw ExtractionPlanCodecError.unsupportedVersion(current.version)
            }
            return ExtractionActivityPlan(
                version: current.version, producer: current.producer?.value, origin: current.origin,
                providerID: current.providerID, modelID: current.modelID, toolVersion: current.toolVersion,
                sourceVersionID: current.sourceVersionID, note: current.note)
        } catch let error as ExtractionPlanCodecError {
            throw error
        } catch {
            do {
                let legacy = try JSONDecoder().decode(LegacyPlan.self, from: data)
                return ExtractionActivityPlan(
                    producer: .backend(legacy.backend), origin: .extraction, modelID: legacy.model)
            } catch {
                throw ExtractionPlanCodecError.malformedJSON
            }
        }
    }
}

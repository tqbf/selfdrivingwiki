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
        private enum CodingKeys: String, CodingKey {
            case version, producer, origin, providerID, modelID, toolVersion, sourceVersionID, note
        }

        let version: Int
        let producer: Producer?
        let origin: SourceMarkdownOrigin
        let providerID: ProviderID?
        let modelID: ModelID?
        let toolVersion: String?
        let sourceVersionID: SourceVersionID?
        let note: String?

        init(
            version: Int,
            producer: Producer?,
            origin: SourceMarkdownOrigin,
            providerID: ProviderID?,
            modelID: ModelID?,
            toolVersion: String?,
            sourceVersionID: SourceVersionID?,
            note: String?
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            origin = try container.decode(SourceMarkdownOrigin.self, forKey: .origin)
            // The producer is the only lossy outer field: a bad payload must
            // not take valid origin, provider, model, version, tool, or note
            // fields with it.
            do {
                producer = try container.decodeIfPresent(ProducerEnvelope.self, forKey: .producer)?.producer
            } catch {
                producer = nil
            }
            providerID = Self.lossyDecode(ProviderID.self, from: container, key: .providerID)
            modelID = Self.lossyDecode(ModelID.self, from: container, key: .modelID)
            toolVersion = Self.lossyDecode(String.self, from: container, key: .toolVersion)
            sourceVersionID = Self.lossyDecode(SourceVersionID.self, from: container, key: .sourceVersionID)
            note = Self.lossyDecode(String.self, from: container, key: .note)
        }

        private static func lossyDecode<Value: Decodable>(
            _ type: Value.Type,
            from container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Value? {
            do {
                return try container.decodeIfPresent(type, forKey: key)
            } catch {
                return nil
            }
        }
    }

    /// Encode-side producer shape. Decoding is deliberately separate so a bad
    /// producer payload can drop the producer without dropping the plan.
    private enum Producer: Encodable {
        case backend(ExtractionBackend)
        case tool(ExtractionTool)
        case legacy(rawTechnique: String?)
        case installedPackage(ExtractionInstalledPackageProducer)

        private enum CodingKeys: String, CodingKey {
            case kind, backend, tool, rawTechnique, installedPackage
        }
        fileprivate enum Kind: String, Codable { case backend, tool, legacy, installedPackage }

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
            case .installedPackage(let package):
                try container.encode(Kind.installedPackage, forKey: .kind)
                try container.encode(package, forKey: .installedPackage)
            }
        }

        init(_ producer: ExtractionProducer) {
            switch producer {
            case .backend(let backend): self = .backend(backend)
            case .tool(let tool): self = .tool(tool)
            case .legacy(let rawTechnique): self = .legacy(rawTechnique: rawTechnique)
            case .installedPackage(let package): self = .installedPackage(package)
            }
        }

        var value: ExtractionProducer {
            switch self {
            case .backend(let backend): return .backend(backend)
            case .tool(let tool): return .tool(tool)
            case .legacy(let rawTechnique): return .legacy(rawTechnique: rawTechnique)
            case .installedPackage(let package): return .installedPackage(package)
            }
        }
    }

    /// Tolerant producer envelope. An unknown producer kind, a missing kind, or
    /// any malformed payload yields no producer instead of failing the plan, so
    /// every valid outer field survives. The tagged plan written by this code
    /// always carries a well-formed producer, so tolerance only affects rows a
    /// future writer or a corrupt row could produce.
    private struct ProducerEnvelope: Decodable {
        let producer: Producer?

        private enum CodingKeys: String, CodingKey {
            case kind, backend, tool, rawTechnique, installedPackage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawKind: String
            do {
                rawKind = try container.decode(String.self, forKey: .kind)
            } catch {
                producer = nil
                return
            }
            guard let kind = Producer.Kind(rawValue: rawKind) else {
                producer = nil
                return
            }
            do {
                switch kind {
                case .backend:
                    producer = .backend(
                        try container.decode(ExtractionBackend.self, forKey: .backend))
                case .tool:
                    producer = .tool(
                        try container.decode(ExtractionTool.self, forKey: .tool))
                case .legacy:
                    producer = .legacy(
                        rawTechnique: try container.decodeIfPresent(String.self, forKey: .rawTechnique))
                case .installedPackage:
                    producer = .installedPackage(
                        try container.decode(ExtractionInstalledPackageProducer.self, forKey: .installedPackage))
                }
            } catch {
                producer = nil
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

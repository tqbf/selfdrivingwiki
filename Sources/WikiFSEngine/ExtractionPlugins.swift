import Cordis
import Foundation
import WikiFSCore

public struct ModelExtractionAdapterConfig: PluginConfig, Equatable {
    public let model: String
    public let baseURL: String

    public init(model: String, baseURL: String) {
        self.model = model
        self.baseURL = baseURL
    }

    public static func validate(_ config: Self) -> [ConfigIssue] {
        var validation = ConfigValidation()
        validation.check("model", !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "model must not be empty")
        validation.check("baseURL", config.resolvedBaseURL != nil, "base URL must be an absolute URL")
        return validation.allIssues
    }

    fileprivate var resolvedBaseURL: URL? {
        guard let url = URL(string: baseURL), url.scheme != nil else { return nil }
        return url
    }
}

public struct DoclingExtractionAdapterConfig: PluginConfig, Equatable {
    public let endpoint: String

    public init(endpoint: String) {
        self.endpoint = endpoint
    }

    public static func validate(_ config: Self) -> [ConfigIssue] {
        var validation = ConfigValidation()
        validation.check("endpoint", URL(string: config.endpoint)?.scheme != nil, "endpoint must be an absolute URL")
        return validation.allIssues
    }
}

public enum ExtractionPlugin {
    public static let id = PluginID("wiki.extraction")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki extraction backends",
        provisions: [ServiceDependency(ExtractionServiceKeys.backends)]
    ) {
        try ComponentDefinition(
            label: "wiki.extraction",
            provisions: [ServiceDependency(ExtractionServiceKeys.backends)]
        ) { activation in
            _ = try await activation.supply(
                ExtractionServiceKeys.backends,
                value: ExtractionBackendRegistry())
        }
    }
}

public enum Pdf2mdExtractionPlugin {
    public static let id = PluginID("wiki.extraction.pdf2md")
    public static let key = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.localPdf2md.rawValue)

    public static func definition(
        makeExtractor: @escaping ExtractionPluginFactory.LocalExtractor
    ) -> PluginDefinition {
        adapterDefinition(id: id, label: "Local pdf2md extraction", key: key) {
            .pdf(ExtractionPreparation(
                extractor: await makeExtractor(),
                backend: .localPdf2md,
                modelVersion: nil))
        }
    }
}

public enum ACPExtractionPlugin {
    public static let id = PluginID("wiki.extraction.acp")
    public static let key = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.acp.rawValue)

    public static func definition(
        configuration: ExtractionConfig,
        resolve: @escaping ExtractionPluginFactory.ACPResolver,
        fallback: @escaping ExtractionPluginFactory.LocalExtractor
    ) -> PluginDefinition {
        adapterDefinition(id: id, label: "ACP extraction", key: key) {
            let extractor: any MarkdownExtractor
            if let resolved = resolve(configuration) {
                extractor = resolved
            } else {
                extractor = await fallback()
            }
            return .pdf(ExtractionPreparation(
                extractor: extractor,
                backend: .acp,
                modelVersion: nil))
        }
    }
}

public enum AnthropicExtractionPlugin {
    public static let id = PluginID("wiki.extraction.anthropic")
    public static let key = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.anthropic.rawValue)

    public static func definition(
        readCredential: @escaping ExtractionPluginFactory.CredentialReader,
        fetcher: any HTTPRequestFetcher
    ) -> PluginDefinition {
        PluginDefinition(
            id: id,
            label: "Anthropic extraction",
            dependencies: [ServiceDependency(ExtractionServiceKeys.backends)],
            config: ModelExtractionAdapterConfig.self
        ) { config in
            try adapterComponent(label: "wiki.extraction.anthropic", key: key) {
                .pdf(ExtractionPreparation(
                    extractor: AnthropicExtractionClient(
                        model: config.model,
                        apiKey: readCredential(.anthropicAPIKey) ?? "",
                        baseURL: config.resolvedBaseURL ?? ExtractionDefaultURL.anthropic,
                        fetcher: fetcher),
                    backend: .anthropic,
                    modelVersion: config.model))
            }
        }
    }
}

public enum GeminiExtractionPlugin {
    public static let id = PluginID("wiki.extraction.gemini")
    public static let key = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.gemini.rawValue)

    public static func definition(
        readCredential: @escaping ExtractionPluginFactory.CredentialReader,
        fetcher: any HTTPRequestFetcher
    ) -> PluginDefinition {
        PluginDefinition(
            id: id,
            label: "Gemini extraction",
            dependencies: [ServiceDependency(ExtractionServiceKeys.backends)],
            config: ModelExtractionAdapterConfig.self
        ) { config in
            try adapterComponent(label: "wiki.extraction.gemini", key: key) {
                .pdf(ExtractionPreparation(
                    extractor: GeminiExtractionClient(
                        model: config.model,
                        apiKey: readCredential(.geminiAPIKey) ?? "",
                        baseURL: config.resolvedBaseURL ?? ExtractionDefaultURL.gemini,
                        fetcher: fetcher),
                    backend: .gemini,
                    modelVersion: config.model))
            }
        }
    }
}

public enum DoclingExtractionPlugin {
    public static let id = PluginID("wiki.extraction.docling")
    public static let key = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.doclingServe.rawValue)

    public static func definition(
        readCredential: @escaping ExtractionPluginFactory.CredentialReader,
        fetcher: any HTTPRequestFetcher
    ) -> PluginDefinition {
        PluginDefinition(
            id: id,
            label: "Docling Serve extraction",
            dependencies: [ServiceDependency(ExtractionServiceKeys.backends)],
            config: DoclingExtractionAdapterConfig.self
        ) { config in
            try adapterComponent(label: "wiki.extraction.docling", key: key) {
                .pdf(ExtractionPreparation(
                    extractor: DoclingServeClient(
                        endpoint: config.endpoint,
                        apiToken: readCredential(.doclingServeToken),
                        fetcher: fetcher),
                    backend: .doclingServe,
                    modelVersion: nil))
            }
        }
    }
}

public enum DefuddleExtractionPlugin {
    public static let id = PluginID("wiki.extraction.defuddle")
    public static let key = ExtractionBackendKey(kind: .html, backendID: HtmlExtractionBackend.defuddle.rawValue)

    public static func definition(
        makeExtractor: @escaping @Sendable () async -> any HtmlMarkdownExtractor
    ) -> PluginDefinition {
        adapterDefinition(id: id, label: "Defuddle extraction", key: key) {
            .html(await makeExtractor())
        }
    }
}

public enum YouTubeTranscriptPlugin {
    public static let id = PluginID("wiki.extraction.youtube-transcript")
    public static let key = ExtractionBackendKey(kind: .youtubeTranscript, backendID: "youtube")

    public static func definition(
        makeFetcher: @escaping @Sendable () async -> any YouTubeTranscriptFetching
    ) -> PluginDefinition {
        adapterDefinition(id: id, label: "YouTube transcripts", key: key) {
            .youtubeTranscript(await makeFetcher())
        }
    }
}

public enum RSSPodcastTranscriptPlugin {
    public static let id = PluginID("wiki.extraction.rss-podcast-transcript")
    public static let key = ExtractionBackendKey(kind: .rssPodcastTranscript, backendID: "rss")

    public static func definition(
        makeFetcher: @escaping @Sendable () async -> any RSSFeedTranscriptFetching
    ) -> PluginDefinition {
        adapterDefinition(id: id, label: "RSS podcast transcripts", key: key) {
            .rssPodcastTranscript(await makeFetcher())
        }
    }
}

public enum ApplePodcastTranscriptPlugin {
    public static let id = PluginID("wiki.extraction.apple-podcast-transcript")
    public static let key = ExtractionBackendKey(
        kind: .applePodcastTranscript,
        backendID: PodcastTranscriptionBackend.appleTranscript.rawValue)

    public static func definition(
        makeFetcher: @escaping @Sendable () async -> any PodcastTranscriptFetching
    ) -> PluginDefinition {
        adapterDefinition(id: id, label: "Apple Podcasts transcripts", key: key) {
            .applePodcastTranscript(await makeFetcher())
        }
    }
}

private func adapterDefinition(
    id: PluginID,
    label: String,
    key: ExtractionBackendKey,
    makeAdapter: @escaping RegisteredExtractionBackend.Factory
) -> PluginDefinition {
    PluginDefinition(
        id: id,
        label: label,
        dependencies: [ServiceDependency(ExtractionServiceKeys.backends)]
    ) {
        try adapterComponent(label: id.rawValue, key: key, makeAdapter: makeAdapter)
    }
}

private func adapterComponent(
    label: String,
    key: ExtractionBackendKey,
    makeAdapter: @escaping RegisteredExtractionBackend.Factory
) throws -> ComponentDefinition {
    try ComponentDefinition(
        label: label,
        dependencies: [ServiceDependency(ExtractionServiceKeys.backends)]
    ) { activation in
        let registry = try await activation.require(ExtractionServiceKeys.backends)
        let registration = try await registry.register(RegisteredExtractionBackend(
            key: key,
            makeAdapter: makeAdapter))
        _ = try await activation.effect { _ in
            await registration.dispose()
        }
    }
}

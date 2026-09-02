import Foundation
import WikiFSCore
import WikiFSTypes

extension WikiRenderContext {
    func documentEmbedResolver(
        sourceRendererCandidates: [SourceID: RendererEmbedPlan] = [:],
        markdownImageTargets: [String: ResolvedMarkdownImageTarget] = [:]
    ) -> DocumentEmbedResolver {
        var pageIDByName: [String: PageID] = [:]
        for (pageID, title) in pageIDToName {
            pageIDByName[title.lowercased()] = pageID
        }

        var chatIDByName: [String: ChatID] = [:]
        for (chatID, title) in chatIDToName {
            chatIDByName[title.lowercased()] = chatID
        }

        var sourceByName: [String: DocumentSourceResolution] = [:]
        for (key, info) in embedMap {
            let displayName = sourceIDToName[info.id] ?? key
            sourceByName[key] = DocumentSourceResolution(
                sourceID: info.id,
                version: nil,
                displayName: displayName,
                mimeType: info.mimeType,
                bytes: nil,
                externalTarget: info.target)
        }

        return DocumentEmbedResolver(inputs: .init(
            pageIDByName: pageIDByName,
            sourceByName: sourceByName,
            sourceLinkNames: sourceNames,
            uniqueSourceLooseKeys: uniqueLooseKeys,
            pageTitlesByID: pageIDToName,
            sourceNamesByID: sourceIDToName,
            chatIDByName: chatIDByName,
            chatTitlesByID: chatIDToName,
            sourceDerivedChain: sourceDerivedChain,
            sourceRendererCandidates: sourceRendererCandidates,
            markdownImageTargets: markdownImageTargets))
    }
}

import Foundation
import WikiFSCore
import WikiFSTypes

extension WikiRenderContext {
    func documentEmbedResolver(
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
            let mermaidText: Data? = {
                guard info.target?.kind == .diagram,
                      let content = info.target?.content else { return nil }
                return Data(content.utf8)
            }()
            sourceByName[key] = DocumentSourceResolution(
                sourceID: info.id,
                version: nil,
                displayName: displayName,
                mimeType: info.mimeType,
                bytes: mermaidText,
                externalTarget: info.target,
                isMermaidSource: info.target?.kind == .diagram)
        }

        return DocumentEmbedResolver(inputs: .init(
            pageIDByName: pageIDByName,
            sourceByName: sourceByName,
            pageTitlesByID: pageIDToName,
            sourceNamesByID: sourceIDToName,
            chatIDByName: chatIDByName,
            chatTitlesByID: chatIDToName,
            sourceDerivedChain: sourceDerivedChain,
            markdownImageTargets: markdownImageTargets))
    }
}

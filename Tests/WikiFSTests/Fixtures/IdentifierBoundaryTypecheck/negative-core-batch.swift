import Foundation
import WikiFSCore
import WikiFSTypes

do {
    // chatIDIsRejectedByChatMessageAPI
    func acceptsMessageID(_ id: ChatMessageID) {}

    let chatID = ChatID(rawValue: "chat-1")
    acceptsMessageID(chatID)
}

do {
    // chatIDIsRejectedByPageAPI
    func chatIDIsRejectedByPageAPI(store: any WikiStore, chatID: ChatID) throws {
        _ = try store.getPage(id: chatID)
    }
}

do {
    // chatIDIsRejectedByProcessedMarkdownVersionAPI
    func chatIDIsRejectedByProcessedMarkdownVersionAPI(store: any WikiStore, chatID: ChatID) throws {
        _ = try store.processedMarkdownVersion(id: chatID)
    }
}

do {
    // chatIDIsRejectedBySourceAPI
    func chatIDIsRejectedBySourceAPI(store: any WikiStore, chatID: ChatID) throws {
        _ = try store.sourceContent(id: chatID)
    }
}

do {
    // markdownVersionIDIsRejectedBySourceVersionAPI
    func markdownVersionIDIsRejectedBySourceVersionAPI(
        store: GRDBWikiStore,
        sourceID: SourceID,
        markdownVersionID: SourceMarkdownVersionID
    ) throws {
        try store.rollbackSourceContent(sourceID: sourceID, to: markdownVersionID)
    }
}

do {
    // pageIDIsRejectedByChatAPI
    func pageIDIsRejectedByChatAPI(store: any WikiStore, pageID: PageID) throws {
        _ = try store.getChat(id: pageID)
    }
}

do {
    // pageIDIsRejectedByChatTurnAPI
    let pageID = PageID(rawValue: "page-1")
    let commandID = ChatCommandID(rawValue: "command-1")

    _ = ChatTurnSubmission(
        commandID: commandID,
        turnID: pageID,
        userText: "Hello",
        contextReferences: [],
        submittedAt: Date(timeIntervalSince1970: 1)
    )
}

do {
    // pageIDIsRejectedByProcessedMarkdownVersionAPI
    func pageIDIsRejectedByProcessedMarkdownVersionAPI(store: any WikiStore, pageID: PageID) throws {
        _ = try store.processedMarkdownVersion(id: pageID)
    }
}

do {
    // pageIDIsRejectedBySourceAPI
    func pageIDIsRejectedBySourceAPI(store: any WikiStore, pageID: PageID) throws {
        _ = try store.sourceContent(id: pageID)
    }
}

do {
    // pageIDIsRejectedBySourceVersionAPI
    func pageIDIsRejectedBySourceVersionAPI(store: GRDBWikiStore, sourceID: SourceID, pageID: PageID) throws {
        try store.rollbackSourceContent(sourceID: sourceID, to: pageID)
    }
}

do {
    // permissionRequestIDIsRejectedByToolCallAPI
    func acceptsToolCallID(_ id: ToolCallID) {}

    let requestID = PermissionRequestID(rawValue: "permission-1")
    acceptsToolCallID(requestID)
}

do {
    // sourceIDIsRejectedByChatAPI
    func sourceIDIsRejectedByChatAPI(store: any WikiStore, sourceID: SourceID) throws {
        _ = try store.getChat(id: sourceID)
    }
}

do {
    // sourceIDIsRejectedByPageAPI
    func sourceIDIsRejectedByPageAPI(store: any WikiStore, sourceID: SourceID) throws {
        _ = try store.getPage(id: sourceID)
    }
}

do {
    // sourceIDIsRejectedByProcessedMarkdownVersionAPI
    func sourceIDIsRejectedByProcessedMarkdownVersionAPI(store: any WikiStore, sourceID: SourceID) throws {
        _ = try store.processedMarkdownVersion(id: sourceID)
    }
}

do {
    // sourceIDIsRejectedBySourceVersionAPI
    func sourceIDIsRejectedBySourceVersionAPI(store: GRDBWikiStore, sourceID: SourceID) throws {
        try store.rollbackSourceContent(sourceID: sourceID, to: sourceID)
    }
}

do {
    // sourceVersionIDIsRejectedByChatAPI
    func sourceVersionIDIsRejectedByChatAPI(store: any WikiStore, sourceVersionID: SourceVersionID) throws {
        _ = try store.getChat(id: sourceVersionID)
    }
}

do {
    // sourceVersionIDIsRejectedByPageAPI
    func sourceVersionIDIsRejectedByPageAPI(store: any WikiStore, sourceVersionID: SourceVersionID) throws {
        _ = try store.getPage(id: sourceVersionID)
    }
}

do {
    // sourceVersionIDIsRejectedByProcessedMarkdownVersionAPI
    func sourceVersionIDIsRejectedByProcessedMarkdownVersionAPI(store: any WikiStore, sourceVersionID: SourceVersionID) throws {
        _ = try store.processedMarkdownVersion(id: sourceVersionID)
    }
}

do {
    // sourceVersionIDIsRejectedBySetActiveMarkdownAPI
    func sourceVersionIDIsRejectedBySetActiveMarkdownAPI(
        store: any WikiStore,
        sourceID: SourceID,
        sourceVersionID: SourceVersionID
    ) throws {
        try store.setActiveMarkdown(sourceID: sourceID, to: sourceVersionID)
    }
}

do {
    // sourceVersionIDIsRejectedBySourceAPI
    func sourceVersionIDIsRejectedBySourceAPI(store: any WikiStore, sourceVersionID: SourceVersionID) throws {
        _ = try store.sourceContent(id: sourceVersionID)
    }
}

do {
    // stringIsRejectedByChatCommandAPI
    func acceptsCommandID(_ id: ChatCommandID) {}

    let raw = "command-1"
    acceptsCommandID(raw)
}

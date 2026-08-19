import WikiFSEngine
import WikiFSTypes

do {
    // pageIDIsRejectedByLauncherChatAPI
    func pageIDIsRejectedByLauncherChatAPI(
        launcher: AgentLauncher,
        wikiID: WikiID,
        pageID: PageID
    ) async {
        await launcher.startInteractiveQuery(
            firstMessage: "hello",
            stateMarkdown: "",
            wikiID: wikiID,
            wikiRoot: "",
            systemPrompt: "",
            wikictlDirectory: "",
            chatID: pageID,
            onLock: {},
            onUnlock: {}
        )
    }
}

do {
    // stringIsRejectedByLauncherChatAPI
    func stringIsRejectedByLauncherChatAPI(
        launcher: AgentLauncher,
        wikiID: WikiID,
        rawChatID: String
    ) async {
        await launcher.startInteractiveQuery(
            firstMessage: "hello",
            stateMarkdown: "",
            wikiID: wikiID,
            wikiRoot: "",
            systemPrompt: "",
            wikictlDirectory: "",
            chatID: rawChatID,
            onLock: {},
            onUnlock: {}
        )
    }
}

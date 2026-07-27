import WikiFSEngine
import WikiFSTypes

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

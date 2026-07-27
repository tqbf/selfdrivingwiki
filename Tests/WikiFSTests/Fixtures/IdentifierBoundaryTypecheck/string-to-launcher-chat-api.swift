import WikiFSEngine
import WikiFSTypes

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

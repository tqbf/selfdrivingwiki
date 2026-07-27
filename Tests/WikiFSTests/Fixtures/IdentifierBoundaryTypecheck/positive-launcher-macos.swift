import WikiFSEngine
import WikiFSTypes

func acceptsLauncherChatIdentifiersOnMacOS(
    launcher: AgentLauncher,
    wikiID: WikiID,
    chatID: ChatID
) async {
    await launcher.startInteractiveQuery(
        firstMessage: "hello",
        stateMarkdown: "",
        wikiID: wikiID,
        wikiRoot: "",
        systemPrompt: "",
        wikictlDirectory: "",
        chatID: chatID,
        onLock: {},
        onUnlock: {},
        onMessageSummary: { persistedChatID in
            _ = persistedChatID
        },
        onStreamingCheckpoint: { persistedChatID, _, _, _ in
            persistedChatID == chatID
        }
    )
}

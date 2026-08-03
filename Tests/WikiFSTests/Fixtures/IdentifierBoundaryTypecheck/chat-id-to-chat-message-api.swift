import WikiFSCore
import WikiFSTypes

func acceptsMessageID(_ id: ChatMessageID) {}

let chatID = ChatID(rawValue: "chat-1")
acceptsMessageID(chatID)

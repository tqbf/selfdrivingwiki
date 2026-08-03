import Foundation
import WikiFSCore
import WikiFSTypes

let pageID = PageID(rawValue: "page-1")
let commandID = ChatCommandID(rawValue: "command-1")

_ = ChatTurnSubmission(
    commandID: commandID,
    turnID: pageID,
    userText: "Hello",
    contextReferences: [],
    submittedAt: Date(timeIntervalSince1970: 1)
)

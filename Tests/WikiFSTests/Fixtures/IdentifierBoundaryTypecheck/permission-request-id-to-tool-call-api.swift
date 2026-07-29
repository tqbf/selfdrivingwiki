import WikiFSTypes

func acceptsToolCallID(_ id: ToolCallID) {}

let requestID = PermissionRequestID(rawValue: "permission-1")
acceptsToolCallID(requestID)

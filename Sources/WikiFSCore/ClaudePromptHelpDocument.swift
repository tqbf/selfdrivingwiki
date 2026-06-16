import Foundation

/// One readable prompt/command artifact shown in the app's Help menu.
public struct ClaudePromptHelpDocument: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let summary: String
  public let body: String

  public init(id: String, title: String, summary: String, body: String) {
    self.id = id
    self.title = title
    self.summary = summary
    self.body = body
  }
}

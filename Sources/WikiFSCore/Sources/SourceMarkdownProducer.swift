import Foundation

public struct SourceMarkdownProducer: Equatable, Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String?) {
        self.name = name
        self.version = version
    }
}

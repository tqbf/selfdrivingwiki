import Foundation

// pattern: Imperative Shell

/// Loads the bounded renderer-package reference appended to each staged wiki
/// state file. It is not a system prompt and does not execute a maintainer skill.
enum RendererPackageGuide {
    static let text: String = {
        guard let url = Bundle.main.url(forResource: "wiki-state-chat-reference", withExtension: "md")
            ?? Bundle.module.url(forResource: "wiki-state-chat-reference", withExtension: "md")
            ?? Bundle.module.url(forResource: "wiki-state-chat-reference", withExtension: "md", subdirectory: "references")
        else {
            fatalError("wiki-state-chat-reference.md is missing from Bundle.main or the WikiFSCore resource bundle.")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("wiki-state-chat-reference.md could not be read from \(url).")
        }
    }()
}

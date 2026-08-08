import Foundation

// pattern: Imperative Shell

/// Loads the bounded renderer-package reference appended to each staged wiki
/// state file. It is not a system prompt and does not execute a maintainer skill.
enum RendererPackageGuide {
    static let text: String = {
        guard let url = Bundle.module.url(forResource: "current-package-guide", withExtension: "md")
            ?? Bundle.module.url(forResource: "current-package-guide", withExtension: "md", subdirectory: "references")
        else {
            fatalError("current-package-guide.md is missing from the WikiFSCore resource bundle.")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("current-package-guide.md could not be read from the WikiFSCore resource bundle.")
        }
    }()
}

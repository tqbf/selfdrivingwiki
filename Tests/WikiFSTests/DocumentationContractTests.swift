import Foundation
import Testing

/// Guards the durable documentation claims for the identifier-boundary docs.
struct DocumentationContractTests {
    private static let planPath = "plans/page-source-id-separation.md"
    private static let progressDirectoryPath = "progress"
    private static let progressHeading = "# 2026-07-27 — PageID and SourceID type separation"
    private static let requiredPlanMarkers = [
        "Identifier boundary:",
        "No-migration decision:",
        "Raw-string boundaries:",
        "Deferred identifier work:",
    ]
    private static let chatPlanPath = "plans/chat-id-separation.md"
    private static let chatProgressHeading = "# 2026-07-27 — ChatID namespace separation (#954)"
    private static let requiredChatPlanMarkers = [
        "Introduce a public `ChatID` namespace for persisted chat entities",
        "Do not alter SQLite schema versions, tables, columns, indexes, foreign keys, or stored ULID text.",
        "Do not introduce a separate `ChatMessageID` in this work; retain `ChatMessage.id: PageID` and document it as deferred.",
        "A non-empty chat API signature manifest passes and the final audit finds no persisted chat entity API still typed as `PageID` or an untagged internal `String`.",
    ]
    private static let sourceVersionPlanPath = "plans/source-version-id-separation.md"
    private static let sourceVersionProgressHeading = "# 2026-07-27 — SourceVersionID separation (#955)"
    private static let requiredSourceVersionPlanMarkers = [
        "Identifier boundary:",
        "No-migration decision:",
        "Raw-string boundaries:",
        "Ref polymorphism:",
        "Deferred markdown-version namespace:",
    ]
    private static let sourceMarkdownVersionPlanPath = "plans/source-markdown-version-id-separation.md"
    private static let dynamicRendererInventoryPath = "plans/dynamic-renderers-phase5-webview-test-inventory.json"
    private static let sourceMarkdownVersionProgressHeading = "# 2026-07-28 — SourceMarkdownVersionID separation (#956)"
    private static let requiredSourceMarkdownVersionPlanMarkers = [
        "Identifier boundary:",
        "No-migration decision:",
        "Raw-string boundaries:",
        "Polymorphic refs and source-link pins:",
        "Rejected cross-namespace calls:",
    ]

    @Test func pageSourceIDPlanIsIndexedAndComplete() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let plan = try String(
            contentsOf: root.appendingPathComponent(Self.planPath),
            encoding: .utf8
        )
        let index = try String(
            contentsOf: root.appendingPathComponent("PLAN.md"),
            encoding: .utf8
        )
        let progress = try Self.readProgressEntries(from: root)

        #expect(index.contains("[`\(Self.planPath)`](\(Self.planPath))"))
        #expect(progress.contains(Self.progressHeading))
        for marker in Self.requiredPlanMarkers {
            #expect(plan.contains(marker), "missing documentation marker: \(marker)")
        }
    }

    @Test func chatIDSeparationContractIsDocumented() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let plan = try String(
            contentsOf: root.appendingPathComponent(Self.chatPlanPath),
            encoding: .utf8
        )
        let index = try String(
            contentsOf: root.appendingPathComponent("PLAN.md"),
            encoding: .utf8
        )
        let progress = try Self.readProgressEntries(from: root)

        #expect(index.contains("[`\(Self.chatPlanPath)`](\(Self.chatPlanPath))"))
        #expect(progress.contains(Self.chatProgressHeading))
        for marker in Self.requiredChatPlanMarkers {
            #expect(plan.contains(marker), "missing chat documentation marker: \(marker)")
        }
    }

    @Test func sourceVersionIDSeparationContractIsDocumented() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let plan = try String(
            contentsOf: root.appendingPathComponent(Self.sourceVersionPlanPath),
            encoding: .utf8
        )
        let index = try String(
            contentsOf: root.appendingPathComponent("PLAN.md"),
            encoding: .utf8
        )
        let progress = try Self.readProgressEntries(from: root)

        #expect(index.contains("[`\(Self.sourceVersionPlanPath)`](\(Self.sourceVersionPlanPath))"))
        #expect(progress.contains(Self.sourceVersionProgressHeading))
        for marker in Self.requiredSourceVersionPlanMarkers {
            #expect(plan.contains(marker), "missing source-version documentation marker: \(marker)")
        }
    }

    @Test func sourceMarkdownVersionIDBoundaryIsDocumented() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let plan = try String(
            contentsOf: root.appendingPathComponent(Self.sourceMarkdownVersionPlanPath),
            encoding: .utf8
        )

        for marker in Self.requiredSourceMarkdownVersionPlanMarkers {
            #expect(plan.contains(marker), "missing source-markdown-version documentation marker: \(marker)")
        }
    }

    @Test func planIndexesSourceMarkdownVersionIDDocument() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let index = try String(
            contentsOf: root.appendingPathComponent("PLAN.md"),
            encoding: .utf8
        )

        #expect(index.contains("[`\(Self.sourceMarkdownVersionPlanPath)`](\(Self.sourceMarkdownVersionPlanPath))"))
    }

    @Test func progressRecordsSourceMarkdownVersionIDVerification() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let progress = try Self.readProgressEntries(from: root)

        #expect(progress.contains(Self.sourceMarkdownVersionProgressHeading))
        #expect(progress.contains("SourceMarkdownVersionAPISignatureManifestTests"))
        #expect(progress.contains("SourceMarkdownVersionIDPersistenceTests"))
    }

    @Test func dynamicRendererFutureSessionInputContractIsVersionPinnedAndHasNoWebViewImplementation() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let inventory = try String(
            contentsOf: root.appendingPathComponent(Self.dynamicRendererInventoryPath),
            encoding: .utf8
        )

        #expect(inventory.contains("WebView security gate preparation; no WebView implementation"))
        #expect(inventory.contains("SourceVersionID"))
        #expect(inventory.contains("SourceMarkdownVersionID"))
        #expect(inventory.contains("must not call live sourceContent(id:) for session input"))
        #expect(inventory.contains("WikiAppWebViewSession"))
    }

    @Test func progressEntriesFollowTemplate() throws {
        let root = try #require(Self.locateRepositoryRoot())
        let entries = try Self.progressEntries(from: root)
        try #require(entries.isEmpty == false, "expected at least one progress entry")

        for entry in entries {
            #expect(
                entry.contents.hasPrefix("---\n"),
                "missing YAML front matter: \(entry.url.lastPathComponent)"
            )
            guard let frontMatterEnd = entry.contents.range(of: "\n---\n") else {
                Issue.record("missing YAML front matter terminator: \(entry.url.lastPathComponent)")
                continue
            }

            let frontMatter = String(entry.contents[..<frontMatterEnd.lowerBound])
            for field in ["timestamp:", "title:", "branch:", "status:"] {
                #expect(
                    frontMatter.contains("\n\(field)"),
                    "missing YAML field '\(field)': \(entry.url.lastPathComponent)"
                )
            }
            #expect(entry.contents.contains("\n# "), "missing title heading: \(entry.url.lastPathComponent)")
            #expect(entry.contents.contains("\n## Progress\n"), "missing progress heading: \(entry.url.lastPathComponent)")
            #expect(entry.contents.contains("\n## Verification\n"), "missing verification heading: \(entry.url.lastPathComponent)")
        }
    }

    private static func locateRepositoryRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func readProgressEntries(from root: URL) throws -> String {
        try progressEntries(from: root)
            .map(\.contents)
            .joined(separator: "\n\n")
    }

    private static func progressEntries(from root: URL) throws -> [ProgressEntry] {
        let progressDirectory = root.appendingPathComponent(progressDirectoryPath)
        let entryURLs = try FileManager.default.contentsOfDirectory(
            at: progressDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let markdownEntries = try entryURLs.filter { entryURL in
            guard
                entryURL.pathExtension == "md",
                entryURL.lastPathComponent != "README.md",
                entryURL.lastPathComponent != "TEMPLATE.md"
            else {
                return false
            }
            return try entryURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        return try markdownEntries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ProgressEntry(url: $0, contents: try String(contentsOf: $0, encoding: .utf8)) }
    }

    private struct ProgressEntry {
        let url: URL
        let contents: String
    }
}

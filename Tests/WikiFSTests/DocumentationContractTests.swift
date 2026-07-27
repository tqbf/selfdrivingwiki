import Foundation
import Testing

/// Guards the durable documentation claims for the PageID and SourceID boundary.
struct DocumentationContractTests {
    private static let planPath = "plans/page-source-id-separation.md"
    private static let progressHeading = "## 2026-07-27 — PageID and SourceID type separation"
    private static let requiredPlanMarkers = [
        "Identifier boundary:",
        "No-migration decision:",
        "Raw-string boundaries:",
        "Deferred identifier work:",
    ]
    private static let chatPlanPath = "plans/chat-id-separation.md"
    private static let chatProgressHeading = "## 2026-07-27 — ChatID namespace separation (#954)"
    private static let requiredChatPlanMarkers = [
        "Introduce a public `ChatID` namespace for persisted chat entities",
        "Do not alter SQLite schema versions, tables, columns, indexes, foreign keys, or stored ULID text.",
        "Do not introduce a separate `ChatMessageID` in this work; retain `ChatMessage.id: PageID` and document it as deferred.",
        "A non-empty chat API signature manifest passes and the final audit finds no persisted chat entity API still typed as `PageID` or an untagged internal `String`.",
    ]
    private static let sourceVersionPlanPath = "plans/source-version-id-separation.md"
    private static let sourceVersionProgressHeading = "## 2026-07-27 — SourceVersionID separation (#955)"
    private static let requiredSourceVersionPlanMarkers = [
        "Identifier boundary:",
        "No-migration decision:",
        "Raw-string boundaries:",
        "Ref polymorphism:",
        "Deferred markdown-version namespace:",
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
        let progress = try String(
            contentsOf: root.appendingPathComponent("PROGRESS.md"),
            encoding: .utf8
        )

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
        let progress = try String(
            contentsOf: root.appendingPathComponent("PROGRESS.md"),
            encoding: .utf8
        )

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
        let progress = try String(
            contentsOf: root.appendingPathComponent("PROGRESS.md"),
            encoding: .utf8
        )

        #expect(index.contains("[`\(Self.sourceVersionPlanPath)`](\(Self.sourceVersionPlanPath))"))
        #expect(progress.contains(Self.sourceVersionProgressHeading))
        for marker in Self.requiredSourceVersionPlanMarkers {
            #expect(plan.contains(marker), "missing source-version documentation marker: \(marker)")
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
}

#if os(macOS)
import Foundation
import Testing

/// The shipped Tool-call-display feature must stay documented: a design
/// record, a PLAN.md index entry, a user guide naming all three modes and the
/// Full Activity behavior, and a completion record under progress/.
struct ChatToolCallSummaryDocumentationContractTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }

    @Test func requiredDocumentsDescribeShippedModesAndActivityBehavior() throws {
        // 1. The design record exists and names the three modes + defaults.
        let designRecord = try read("plans/chat-tool-call-summary.md")
        for expected in ["Summary", "Detailed", "Hidden", "chat.toolCallDisplayMode", "Full Activity"] {
            #expect(designRecord.contains(expected), "design record must mention \(expected)")
        }

        // 2. PLAN.md indexes the design record.
        let plan = try read("PLAN.md")
        #expect(plan.contains("plans/chat-tool-call-summary.md"))

        // 3. The user guide names all three modes, the Settings location, and
        //    the Full Activity behavior.
        let userGuide = try read("docs/user-guide/chat.md")
        for expected in [
            "Summary",
            "Detailed",
            "Hidden",
            "Settings",
            "Appearance",
            "Tool activity",
            "Full Activity",
        ] {
            #expect(userGuide.contains(expected), "user guide must mention \(expected)")
        }
        #expect(userGuide.contains("Hide tool calls") == false)

        // 4. One completion record exists for this feature.
        let progressDirectory = repositoryRoot.appending(path: "progress")
        let enumerator = try #require(FileManager.default.enumerator(
            at: progressDirectory,
            includingPropertiesForKeys: nil
        ))
        let records = enumerator.compactMap { $0 as? URL }.filter { url in
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return contents.contains("chat-tool-call-summary") || contents.contains("Tool activity")
        }
        #expect(records.count >= 1, "expected a completion record for the tool-activity summary")
    }
}
#endif

#if os(macOS)
import XCTest
import Foundation
import ACPModel
@testable import WikiFSEngine

/// Unit tests for `DebugRunLogger` — verifies the folder structure, JSON
/// validity, and best-effort behavior (no throw on failure).
final class DebugRunLoggerTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugRunLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testNilFolderReturnsNil() {
        // When folderURL is nil, the logger is disabled (returns nil).
        XCTAssertNil(DebugRunLogger(folderURL: nil))
    }

    func testCreatesDebugFolderStructure() throws {
        let debugURL = tempDir.appendingPathComponent("debug", isDirectory: true)
        let logger = DebugRunLogger(folderURL: debugURL)
        XCTAssertNotNil(logger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: debugURL.path))
        let turnsURL = debugURL.appendingPathComponent("turns", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: turnsURL.path))
    }

    func testTurnFilesAreWritten() throws {
        let debugURL = tempDir.appendingPathComponent("debug", isDirectory: true)
        guard let logger = DebugRunLogger(folderURL: debugURL) else {
            return XCTFail("Logger should be created")
        }
        let turn = logger.nextTurn()
        XCTAssertEqual(turn, 1)

        // Write a prompt request.
        let sessionId = SessionId("test-session")
        logger.logPromptRequest(text: "Hello, agent", sessionId: sessionId, turn: turn)

        // Write an update notification.
        let notification = JSONRPCNotification(method: "session/update", params: nil)
        logger.logUpdate(notification, turn: turn)

        // Write a prompt response.
        let response = SessionPromptResponse(stopReason: .endTurn, usage: nil, _meta: nil)
        logger.logPromptResponse(response, turn: turn)

        // Verify the prompt file exists and is valid JSON.
        let promptURL = debugURL.appendingPathComponent("turns", isDirectory: true)
            .appendingPathComponent("turn-1-prompt.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: promptURL.path))
        let promptData = try Data(contentsOf: promptURL)
        let promptObj = try JSONSerialization.jsonObject(with: promptData)
        XCTAssertNotNil(promptObj as? [String: Any])

        // Verify the updates file exists, has one JSON line, and is valid.
        let updatesURL = debugURL.appendingPathComponent("turns", isDirectory: true)
            .appendingPathComponent("turn-1-updates.jsonl", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: updatesURL.path))
        let updatesData = try Data(contentsOf: updatesURL)
        let updatesStr = String(data: updatesData, encoding: .utf8) ?? ""
        let lines = updatesStr.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        let updateObj = try JSONSerialization.jsonObject(
            with: lines[0].data(using: .utf8)!)
        XCTAssertNotNil(updateObj as? [String: Any])

        // Verify the response file exists and is valid JSON.
        let responseURL = debugURL.appendingPathComponent("turns", isDirectory: true)
            .appendingPathComponent("turn-1-response.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseURL.path))
        let responseData = try Data(contentsOf: responseURL)
        let responseObj = try JSONSerialization.jsonObject(with: responseData)
        XCTAssertNotNil(responseObj as? [String: Any])
    }

    func testTurnCounterIncrements() {
        let debugURL = tempDir.appendingPathComponent("debug", isDirectory: true)
        guard let logger = DebugRunLogger(folderURL: debugURL) else {
            return XCTFail("Logger should be created")
        }
        XCTAssertEqual(logger.nextTurn(), 1)
        XCTAssertEqual(logger.nextTurn(), 2)
        XCTAssertEqual(logger.nextTurn(), 3)
    }

    func testStderrAppend() throws {
        let debugURL = tempDir.appendingPathComponent("debug", isDirectory: true)
        guard let logger = DebugRunLogger(folderURL: debugURL) else {
            return XCTFail("Logger should be created")
        }
        logger.logStderr("line 1\n")
        logger.logStderr("line 2\n")
        let stderrURL = debugURL.appendingPathComponent("stderr.log", isDirectory: false)
        let content = try String(contentsOf: stderrURL, encoding: .utf8)
        XCTAssertTrue(content.contains("line 1"))
        XCTAssertTrue(content.contains("line 2"))
    }

    func testSummaryIsWritten() throws {
        let debugURL = tempDir.appendingPathComponent("debug", isDirectory: true)
        guard let logger = DebugRunLogger(folderURL: debugURL) else {
            return XCTFail("Logger should be created")
        }
        let summary = DebugRunSummary.from(
            provider: "claude",
            model: "sonnet",
            kind: "ingest",
            startedAt: Date(timeIntervalSince1970: 1000),
            finishedAt: Date(timeIntervalSince1970: 1010),
            usage: nil,
            phases: [])
        logger.logSummary(summary)
        let summaryURL = debugURL.appendingPathComponent("summary.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        let data = try Data(contentsOf: summaryURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["provider"] as? String, "claude")
        XCTAssertEqual(obj?["kind"] as? String, "ingest")
        XCTAssertEqual(obj?["durationSeconds"] as? Double, 10.0)
    }

    func testSessionNewIsWritten() throws {
        let debugURL = tempDir.appendingPathComponent("debug", isDirectory: true)
        guard let logger = DebugRunLogger(folderURL: debugURL) else {
            return XCTFail("Logger should be created")
        }
        let session = NewSessionResponse(sessionId: SessionId("s1"))
        logger.logSessionNew(session, sessionId: SessionId("s1"), workingDirectory: "/tmp")
        let url = debugURL.appendingPathComponent("session-new.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSessionNewSecondSessionUsesIndex() throws {
        let debugURL = tempDir.appendingPathComponent("debug", isDirectory: true)
        guard let logger = DebugRunLogger(folderURL: debugURL) else {
            return XCTFail("Logger should be created")
        }
        let session = NewSessionResponse(sessionId: SessionId("s1"))
        logger.logSessionNew(session, sessionId: SessionId("s1"), workingDirectory: nil)
        logger.logSessionNew(session, sessionId: SessionId("s2"), workingDirectory: nil)
        let url1 = debugURL.appendingPathComponent("session-new.json", isDirectory: false)
        let url2 = debugURL.appendingPathComponent("session-new-2.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path))
    }
}
#endif // os(macOS)

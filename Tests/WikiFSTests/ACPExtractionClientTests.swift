#if os(macOS)
import Foundation
import Testing
import WikiFSEngine
import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for `ACPExtractionClient` — specifically the delta collection fix.
///
/// The bug was that `ACPExtractionClient.convert` only collected `.assistantText`
/// events, but `ACPBackend` emits `.assistantTextDelta` during streaming. This
/// test file verifies that delta chunks are properly concatenated.
struct ACPExtractionClientTests {

    // MARK: - Delta collection (regression test)

    @Test func convert_collectsAssistantTextDelta() async throws {
        // Regression test for issue where .assistantTextDelta events were silently
        // dropped because only .assistantText was handled in the collection loop.
        // ACPBackend emits deltas during streaming — this test verifies they're
        // concatenated correctly.
        var collectedText = ""
        let events: [AgentEvent] = [
            .assistantTextDelta("# Hello\n\n"),
            .assistantTextDelta("This is "),
            .assistantTextDelta("extracted "),
            .assistantTextDelta("markdown."),
            .messageStop
        ]

        for event in events {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if !isError && collectedText.isEmpty {
                    collectedText = text
                }
            default:
                break
            }
        }

        #expect(collectedText == "# Hello\n\nThis is extracted markdown.")
    }

    @Test func convert_mixedAssistantTextAndDelta() async throws {
        // Some backends may emit both .assistantText and .assistantTextDelta —
        // verify both are collected and concatenated.
        var collectedText = ""
        let events: [AgentEvent] = [
            .assistantText("Full "),
            .assistantTextDelta("delta "),
            .assistantTextDelta("chunks."),
            .messageStop
        ]

        for event in events {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if !isError && collectedText.isEmpty {
                    collectedText = text
                }
            default:
                break
            }
        }

        #expect(collectedText == "Full delta chunks.")
    }

    @Test func convert_resultFallbackWhenNoDeltas() async throws {
        // Some agents emit everything in .result instead of streaming deltas —
        // the result should be taken as fallback when collected text is empty.
        var collectedText = ""
        let events: [AgentEvent] = [
            .result(isError: false, text: "Result-based markdown."),
            .messageStop
        ]

        for event in events {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if !isError && collectedText.isEmpty {
                    collectedText = text
                }
            default:
                break
            }
        }

        #expect(collectedText == "Result-based markdown.")
    }

    @Test func convert_errorResultDoesNotOverrideCollectedText() async throws {
        // An error .result should NOT override already-collected delta text.
        var collectedText = ""
        let events: [AgentEvent] = [
            .assistantTextDelta("Collected "),
            .assistantTextDelta("text."),
            .result(isError: true, text: "Error message."),
            .messageStop
        ]

        var turnError: String?
        for event in events {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if isError {
                    turnError = text
                } else if collectedText.isEmpty {
                    collectedText = text
                }
            default:
                break
            }
        }

        #expect(collectedText == "Collected text.")
        #expect(turnError == "Error message.")
    }

    // MARK: - Read-only scratch sandbox (issue #1276)

    /// AC.2: the production extraction profile is read-only, sandboxed to the
    /// EXACT staging directory (both `scratchDirectory` and the invocation's
    /// `SCRATCH_DIR` define), and carries NO wiki database define.
    @Test func extractionProfileUsesReadOnlyScratchSandbox() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-extraction-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: staging) }
            catch { Issue.record("staging cleanup failed: \(error)") }
        }
        let scratch = try LLMSandboxScratch.adopt(directory: staging)

        let profile = ACPExtractionClient.makeProfile(
            providerHints: [HintKey.acpAgentPath.rawValue: "/usr/local/bin/claude"],
            scratch: scratch)

        // The staging directory IS the scratch — the child's cwd and the only
        // writable subtree.
        #expect(profile.scratchDirectory?.path == staging.path)
        #expect(profile.isReadOnly)
        let sandbox = try #require(profile.sandbox, "extraction profiles must name a sandbox")
        let scratchDefine = sandbox.defines.first { $0.0 == "SCRATCH_DIR" }
        #expect(scratchDefine?.1 == SandboxProfile.canonical(staging.path),
                "SCRATCH_DIR must be the exact staging directory (canonical seatbelt form)")
        // NO wiki database — extraction never writes the wiki.
        #expect(sandbox.defines.contains { $0.0 == "WIKI_DB" } == false)
        #expect(sandbox.profile.contains("(deny file-write*)"),
                "the profile must default-deny writes")
        #expect(sandbox.profile.contains("(allow file-write* (subpath (param \"SCRATCH_DIR\")))"))
        // The scratch-local temp root exists BEFORE the child starts.
        #expect(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent(".tmp").path))
    }

    /// AC.5 + AC.8: an unusable sandbox front-end surfaces as
    /// `Error.spawnFailed` (the `ACPBackendError.sandboxUnavailable` message
    /// mapped through the existing error seam) — and the mapping is exercised
    /// through `convert` with an injected failing backend factory.
    @Test func convert_mapsSandboxStartFailure() async throws {
        let sandboxMessage = "The agent sandbox could not be set up (sandbox-exec unavailable)."
        let client = makeClient(backendFactory: { _ in
            throw NSError(
                domain: "acp-sandbox-test",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: sandboxMessage])
        })
        do {
            _ = try await client.convert(
                pdfData: Data("%PDF-1.4 tiny".utf8),
                filename: "doc.pdf",
                onProgress: nil)
            Issue.record("convert must throw when the backend cannot start")
        } catch let error as ACPExtractionClient.Error {
            guard case .spawnFailed(let message) = error else {
                Issue.record("expected .spawnFailed, got \(error)")
                return
            }
            #expect(message.contains(sandboxMessage),
                    "the sandbox-unavailable text must surface through .spawnFailed")
        }
    }

    /// AC.8: a mid-turn failure still maps to `Error.turnFailed` (unchanged
    /// error surface — only the confinement changed).
    @Test func convert_mapsTurnFailure() async throws {
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [
                .turnFailed(reason: .agentError("provider exploded")),
                .messageStop,
            ])
        ])
        let client = makeClient(backendFactory: { _ in backend })
        do {
            _ = try await client.convert(
                pdfData: Data("%PDF-1.4 tiny".utf8),
                filename: "doc.pdf",
                onProgress: nil)
            Issue.record("convert must throw on a failed turn")
        } catch let error as ACPExtractionClient.Error {
            #expect(error == .turnFailed("provider exploded"))
        }
        // One-shot: the session is cancelled on the failure path too.
        let cancelled = await backend.cancelledSessionIDs
        #expect(cancelled.count == 1)
    }

    /// A minimal extraction client wired to `backendFactory` (issue #1276
    /// injectable) for end-to-end `convert` error-mapping coverage.
    private func makeClient(
        backendFactory: @escaping @Sendable (PermissionPolicy) throws -> any AgentBackend
    ) -> ACPExtractionClient {
        ACPExtractionClient(
            provider: AgentProvider(
                id: ProviderID(rawValue: "claude"),
                label: "Claude",
                command: ["/usr/local/bin/claude"]),
            resolvedCommand: ["/usr/local/bin/claude"],
            apiKey: nil,
            containerDirectory: FileManager.default.temporaryDirectory,
            backendFactory: backendFactory)
    }
}
#endif // os(macOS)
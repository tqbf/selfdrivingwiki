import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

/// Tests for `LLMSandboxScratch` — the typed scratch world owned by each
/// read-only LLM child (issue #1276). Covers the strict-profile flag: strict
/// must select `SandboxProfile.strictReadOnlyInvocation` (the trailer present)
/// while the default keeps the plain read-only invocation, and both shapes
/// keep the identical directory contract (unique dir, `.tmp` leaf).
struct LLMSandboxScratchTests {

  private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("llm-scratch-tests-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func make_defaultIsPlainReadOnly() throws {
    let root = tempRoot()
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("cleanup failed: \(error)") }
    }
    let scratch = try LLMSandboxScratch.make(under: root, namePrefix: "plain")
    #expect(scratch.sandbox.trailer.isEmpty, "the default is the plain read-only profile")
    #expect(scratch.sandbox.profile.contains("(deny file-write*)"))
    #expect(scratch.sandbox.profile.contains("(deny process-exec* (subpath (param \"SCRATCH_DIR\")))") == false)
    #expect(FileManager.default.fileExists(atPath: scratch.tempDirectoryURL.path))
  }

  @Test func make_strictSelectsTheStrictTrailer() throws {
    let root = tempRoot()
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("cleanup failed: \(error)") }
    }
    let scratch = try LLMSandboxScratch.make(
      under: root, namePrefix: "strict", strict: true)
    #expect(scratch.sandbox.trailer.isEmpty == false)
    #expect(scratch.sandbox.trailer.contains(
      "(deny process-exec* (subpath (param \"SCRATCH_DIR\")))"))
    #expect(sandbox(scratch).trailer.contains { $0.contains("/.ssh") })
    // Identical directory contract either way.
    #expect(FileManager.default.fileExists(atPath: scratch.tempDirectoryURL.path))
  }

  @Test func adopt_strictMatchesMake() throws {
    let root = tempRoot()
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("cleanup failed: \(error)") }
    }
    let directory = root.appendingPathComponent("adopted-strict", isDirectory: true)
    let scratch = try LLMSandboxScratch.adopt(directory: directory, strict: true)
    let made = try LLMSandboxScratch.make(under: root, namePrefix: "strict", strict: true)
    #expect(scratch.sandbox.trailer == made.sandbox.trailer)
    #expect(scratch.sandbox.baseProfile == made.sandbox.baseProfile)
    #expect(scratch.directoryURL == directory)
    #expect(scratch.tempDirectoryURL == directory.appendingPathComponent(".tmp"))
  }

  /// `remove()` is strict-agnostic: the tree goes away either way.
  @Test func remove_clearsTheTreeForBothTiers() throws {
    let root = tempRoot()
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("cleanup failed: \(error)") }
    }
    let strict = try LLMSandboxScratch.make(under: root, namePrefix: "strict", strict: true)
    let plain = try LLMSandboxScratch.make(under: root, namePrefix: "plain")
    strict.remove()
    plain.remove()
    #expect(!FileManager.default.fileExists(atPath: strict.directoryURL.path))
    #expect(!FileManager.default.fileExists(atPath: plain.directoryURL.path))
  }

  private func sandbox(_ scratch: LLMSandboxScratch) -> SandboxProfile.SandboxInvocation {
    scratch.sandbox
  }
}

import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the seatbelt sandbox config — load/save round-trip, missing/corrupt →
/// default, and the extra-allowed-paths parser (tilde expansion, blanks, relative
/// drop). Mirrors `AgentCommandConfigTests`.
struct SandboxConfigTests {

  // MARK: - Defaults

  @Test func defaultIsDisabledWithEmptyAllowedPaths() {
    let config = SandboxConfig.default
    #expect(config.enabled == false)
    #expect(config.extraAllowedPaths == "")
  }

  @Test func defaultFileNameIsStable() {
    #expect(SandboxConfig.fileName == "sandbox-config.json")
  }

  // MARK: - Persistence

  @Test func roundTripsThroughJSON() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbconfig-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = SandboxConfig(enabled: true, extraAllowedPaths: "/tmp/one\n/tmp/two")
    try original.save(to: dir)

    let loaded = SandboxConfig.load(from: dir)
    #expect(loaded == original)
    #expect(loaded.enabled == true)
    #expect(loaded.extraAllowedPaths == "/tmp/one\n/tmp/two")
  }

  /// Mirrors the exact load→mutate-`enabled`→save round-trip performed by
  /// `AgentCommandSettingsView.saveSandbox()`: a pre-existing `extraAllowedPaths`
  /// must survive an `enabled`-only mutation.
  @Test func mutatingEnabledPreservesExtraAllowedPaths() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbconfig-toggle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Step 1: save an initial config with paths set and sandbox off.
    let initial = SandboxConfig(enabled: false, extraAllowedPaths: "/some/path\n/other")
    try initial.save(to: dir)

    // Step 2: simulate saveSandbox() — load, flip enabled, save.
    var loaded = SandboxConfig.load(from: dir)
    loaded.enabled = true
    try loaded.save(to: dir)

    // Step 3: reload and assert both fields survived.
    let reloaded = SandboxConfig.load(from: dir)
    #expect(reloaded.enabled == true)
    #expect(reloaded.extraAllowedPaths == "/some/path\n/other")
  }

  @Test func missingFileDegradesToDefault() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbconfig-missing-\(UUID().uuidString)")
    let loaded = SandboxConfig.load(from: dir)
    #expect(loaded == .default)
    #expect(loaded.enabled == false)
  }

  @Test func corruptFileDegradesToDefault() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbconfig-corrupt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent(SandboxConfig.fileName, isDirectory: false)
    try "{ this is not valid json".data(using: .utf8)!.write(to: url)

    let loaded = SandboxConfig.load(from: dir)
    #expect(loaded == .default)
    #expect(loaded.enabled == false)
  }

  /// Simulates the full `saveSandbox()` flow when `sandbox-config.json` is corrupt:
  /// load degrades to `.default`, we set `enabled = true`, save succeeds, and the
  /// reloaded config reflects the toggle with empty `extraAllowedPaths` (graceful
  /// degradation — no crash, no data invented).
  @Test func saveSandboxOnCorruptFileDegradesToDefault() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbconfig-corrupt-save-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Pre-seed a corrupt file.
    let url = dir.appendingPathComponent(SandboxConfig.fileName, isDirectory: false)
    try "{not json".data(using: .utf8)!.write(to: url)

    // Simulate saveSandbox(): load (degrades to .default), flip enabled, save.
    var config = SandboxConfig.load(from: dir)
    config.enabled = true
    try config.save(to: dir)

    // Reload: enabled reflects the toggle; extraAllowedPaths is empty (from .default).
    let reloaded = SandboxConfig.load(from: dir)
    #expect(reloaded.enabled == true)
    #expect(reloaded.extraAllowedPaths == "")
  }

  // MARK: - parsedExtraAllowedPaths

  @Test func parsesAbsolutePathsOnePerLine() {
    let config = SandboxConfig(enabled: true, extraAllowedPaths: "/tmp/a\n/tmp/b\n/tmp/c")
    #expect(config.parsedExtraAllowedPaths() == ["/tmp/a", "/tmp/b", "/tmp/c"])
  }

  @Test func skipsBlankAndWhitespaceOnlyLines() {
    let config = SandboxConfig(enabled: true, extraAllowedPaths: "/tmp/a\n\n   \n/tmp/b")
    #expect(config.parsedExtraAllowedPaths() == ["/tmp/a", "/tmp/b"])
  }

  @Test func expandsLeadingTilde() {
    let config = SandboxConfig(enabled: true, extraAllowedPaths: "~/Documents\n~/.cache")
    let paths = config.parsedExtraAllowedPaths()
    #expect(paths.count == 2)
    // Both must be absolute after expansion.
    #expect(paths.allSatisfy { $0.hasPrefix("/") })
    #expect(paths.contains { $0.hasSuffix("/Documents") })
    #expect(paths.contains { $0.hasSuffix("/.cache") })
  }

  @Test func dropsRelativeAndUnresolvableEntries() {
    // A bare `~` that fails to expand stays as `~` (not absolute) → dropped.
    // Relative paths are dropped. Absolute paths survive.
    let config = SandboxConfig(
      enabled: true,
      extraAllowedPaths: "relative/path\n/tmp/ok\n~/ok-sub")
    let paths = config.parsedExtraAllowedPaths()
    #expect(paths.contains("/tmp/ok"))
    // `~/ok-sub` expands to an absolute path.
    #expect(paths.contains { $0.hasSuffix("/ok-sub") })
    // The relative entry never survives.
    #expect(!paths.contains("relative/path"))
  }
}

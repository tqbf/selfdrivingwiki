import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiFSEngine

/// The audio-acquire package's auxiliary-runtime (Bun) grant.
///
/// The grant is per EXACT reviewed revision: the audio package's pinned
/// digest receives its own typed wire kind
/// (`reviewed-audio-acquire-bun-runtime`), a copied revision with the same
/// package ID and claims receives nothing, the caption lineage never sees
/// the audio grant, and an executable that drifted after resolution has
/// its grant withheld.
@Suite("Audio acquire runtime grant")
struct AudioAcquireRuntimeGrantTests {

    // MARK: - Fixtures

    private func tempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-audiogrant-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeExecutable(named name: String, bytes: Data, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func resolution(for url: URL) throws -> RuntimeCommandResolution {
        guard case .identity(let identity) = RuntimeFileProbe.probe(url) else {
            Issue.record("fixture runtime is not a usable executable: \(url.path)")
            throw ExtractorValidationError.invalidManifest("fixture runtime")
        }
        return RuntimeCommandResolution(
            command: AuxiliaryRuntimePolicies.bun.name,
            source: .loginShell,
            executableURL: url,
            identity: identity,
            description: RuntimePathDescription(
                redactedPath: url.path,
                basename: url.lastPathComponent,
                fingerprint: "fixture"))
    }

    /// A copied revision: the audio package's ID and version with a
    /// DIFFERENT digest — a different byte payload is not this package.
    private var copiedRevision: ExtractorPackageRevisionID {
        ExtractorPackageRevisionID(
            packageID: ReviewedExtractorPackages.audioAcquire.packageID,
            version: ReviewedExtractorPackages.audioAcquire.version,
            digest: try! ExtractorPackageDigest(
                hex: String(repeating: "a", count: 64)))
    }

    // MARK: - Exact revision admission

    @Test func requiresExactReviewedRevision() throws {
        // The exact reviewed revision is admitted.
        #expect(ProcessExtractorProvider.wantsAuxiliaryRuntime(
            ReviewedExtractorPackages.audioAcquire.revision))
        // The caption lineage keeps its own admission.
        #expect(ProcessExtractorProvider.wantsAuxiliaryRuntime(
            ReviewedExtractorPackages.youtubeTranscript.revision))
        // A copy — same package ID, same version, different digest — is
        // NOT this package and receives nothing.
        #expect(ProcessExtractorProvider.wantsAuxiliaryRuntime(copiedRevision) == false)
        // Unrelated reviewed revisions were never granted.
        #expect(ProcessExtractorProvider.wantsAuxiliaryRuntime(
            ReviewedExtractorPackages.zotero.revision) == false)
    }

    // MARK: - Wire-kind isolation and identity drift

    @Test func grantsTheAudioWireKindOnlyToTheAudioRevision() throws {
        let root = try tempDirectory("wirekind")
        defer { try? FileManager.default.removeItem(at: root) }
        let bun = try writeExecutable(
            named: "bun", bytes: Data("#!/bin/sh\nexit 0\n".utf8), in: root)
        let retained = AuxiliaryRuntimeOutcome.resolved(try resolution(for: bun))

        // The audio revision receives the AUDIO wire kind.
        let audioConfiguration = ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
            retained: retained, revision: ReviewedExtractorPackages.audioAcquire.revision)
        #expect(audioConfiguration == .audioAcquireBunRuntime(executablePath: bun.path))

        // The caption revision receives the CAPTION wire kind — never the
        // audio grant.
        let youTubeConfiguration = ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
            retained: retained, revision: ReviewedExtractorPackages.youtubeTranscript.revision)
        #expect(youTubeConfiguration == .reviewedYouTubeBunRuntime(executablePath: bun.path))
    }

    @Test func rejectsExecutableIdentityDrift() throws {
        let root = try tempDirectory("drift")
        defer { try? FileManager.default.removeItem(at: root) }
        let bun = try writeExecutable(
            named: "bun", bytes: Data("#!/bin/sh\nexit 0\n".utf8), in: root)
        let pinned = try resolution(for: bun)

        // The executable is rewritten AFTER resolution: the on-disk
        // identity no longer matches the pinned resolution.
        let rewritten = try writeExecutable(
            named: "bun", bytes: Data("#!/bin/sh\necho tampered\n".utf8), in: root)
        #expect(rewritten.path == pinned.executableURL.path)

        let drifted = AuxiliaryRuntimeOutcome.resolved(pinned)
        #expect(ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
            retained: drifted,
            revision: ReviewedExtractorPackages.audioAcquire.revision) == nil)
        // The caption lineage is drifted-guarded the same way.
        #expect(ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
            retained: drifted,
            revision: ReviewedExtractorPackages.youtubeTranscript.revision) == nil)

        // An unavailable runtime never yields a grant.
        #expect(ProcessExtractorProvider.auxiliaryRuntimeConfiguration(
            retained: .unavailable(.versionProbeFailed),
            revision: ReviewedExtractorPackages.audioAcquire.revision) == nil)
    }
}

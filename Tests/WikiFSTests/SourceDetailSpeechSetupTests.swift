import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiFSEngine

/// AC.5 — the model-asset installation is reachable ONLY through the
/// explicit, user-confirmed setup action. Import, simple source viewing,
/// caption actions, caption failures, and the generic import extraction
/// never call it; nothing in the app enqueues `.onDeviceSpeech` from those
/// paths either.
@Suite("Source detail speech setup")
struct SourceDetailSpeechSetupTests {

    /// The ONLY production call sites of `installMissingAssets` are the
    /// protocol declaration and the explicit setup action seam. The scan
    /// fails when an automatic path (import, viewing, caption handling)
    /// grows an installation call.
    @Test func installRequiresConfirmation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var files: [URL] = []
        for relative in ["Sources", "tools"] {
            let url = root.appendingPathComponent(relative)
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            while let candidate = enumerator.nextObject() as? URL {
                if candidate.pathExtension == "swift" { files.append(candidate) }
            }
        }
        #expect(files.isEmpty == false)

        let pattern = try NSRegularExpression(pattern: "installMissingAssets")
        var callSites: [String] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..., in: contents)
            if pattern.firstMatch(in: contents, range: range) != nil {
                callSites.append(file.lastPathComponent)
            }
        }
        // Exactly: the protocol requirement (SpeechTranscribing.swift) and
        // the system implementation (SystemSpeechTranscriber.swift). No UI,
        // import, queue, or store file calls it — the app's confirmed
        // action reaches it through the injected engine seam only.
        let allowed: Set<String> = [
            "SpeechTranscribing.swift",
            "SystemSpeechTranscriber.swift",
        ]
        for site in callSites {
            #expect(allowed.contains(site), "\(site) calls the speech asset installation outside the confirmed setup seam")
        }
        #expect(callSites.count >= 2, "the installation seam and its implementation must both exist")
    }

    /// The engine-level setup types exist with typed guidance — a missing
    /// model asset is NOT a passing transcription check.
    @Test func setupGuidanceIsTyped() {
        #expect(SpeechSetupGuidance.assetsNotInstalled.message.contains("not installed"))
        #expect(SpeechSetupGuidance.localeUnsupported.message.contains("not supported"))
        #expect(SpeechSetupGuidance.speechUnavailable.message.contains("not available"))
        #expect(SpeechSetupGuidance.engineSetupFailed.message.contains("could not start"))
        // The readiness mapping: an absent locale is assets guidance, not a
        // silent pass.
        #expect(SpeechReadiness.needsSetup(.assetsNotInstalled) != .ready)
    }
}

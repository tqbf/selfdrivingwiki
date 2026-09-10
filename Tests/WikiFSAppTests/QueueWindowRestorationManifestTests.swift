import Foundation
import Testing

/// Pins the queue Activity windows' scene-restoration contract: the Agent
/// Queue / Extraction Queue `WindowGroup` must disable scene restoration so
/// both windows ALWAYS start closed on launch and require an explicit open
/// each session (menu item, CTA, or deep link). Durable queue data and
/// reports live in the store and are unaffected; explicit opens during a
/// session are unaffected.
///
/// Launch-time scene restoration is not observable from a unit test host, so
/// the declaration itself is pinned — the same source-manifest pattern
/// `ChatPresentationAPIManifestTests` uses. Exactly one queue window group
/// exists; the modifier must be attached to it and appear exactly once so it
/// is never silently dropped (or copy-pasted onto an unrelated scene).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct QueueWindowRestorationManifestTests {
    private func appSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: "Sources/WikiFS/Window/WikiFSApp.swift"),
            encoding: .utf8)
    }

    @Test func queueWindowGroupDisablesSceneRestoration() throws {
        let source = try appSource()
        // The queue window group exists and disables restoration.
        #expect(
            source.contains("WindowGroup(\"Agent Queue\", for: QueueKind.self)"),
            "The queue Activity windows must stay one WindowGroup keyed by QueueKind")
        #expect(
            source.contains(".restorationBehavior(.disabled)"),
            "The queue window group must disable scene restoration — the windows start closed every launch")
        // Exactly once: never dropped, never duplicated onto another scene.
        let occurrences = source.components(separatedBy: ".restorationBehavior(.disabled)").count - 1
        #expect(
            occurrences == 1,
            "restorationBehavior(.disabled) must be declared exactly once, on the queue window group (got \(occurrences))")
    }
}

#if os(macOS)
import AppKit
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Pins the menu-bar Maintenance submenu shape: it must contain a
/// "Restart Daemon" item wired (target + action) back to the
/// `MenuBarItemController`. The `SMAppService` unregister/register calls
/// inside the action can't be exercised in a unit test (launchd state is
/// not controllable from here), so this only verifies the menu wiring —
/// that the item exists, is enabled, targets the controller, and resolves
/// to the `restartDaemon:` selector. A regression that removes the item,
/// drops its target, or renames the selector is caught here.
@MainActor
struct MenuBarItemMaintenanceMenuTests {

    @Test("Maintenance submenu includes a wired Restart Daemon item")
    func restartDaemonMenuItemExists() throws {
        let controller = try makeController()
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        // Locate the Maintenance submenu.
        let maintenance = try #require(
            menu.items.first(where: { $0.title == "Maintenance" }),
            "Maintenance menu item should be present")
        let submenu = try #require(maintenance.submenu, "Maintenance should have a submenu")

        // Vacuum All… is the anchor item — assert it's still there so a
        // future edit can't silently drop the pre-existing entry.
        #expect(submenu.items.contains(where: { $0.title == "Vacuum All…" }))

        let restart = try #require(
            submenu.items.first(where: { $0.title == "Restart Daemon" }),
            "Restart Daemon item should be present in the Maintenance submenu")

        #expect(restart.isEnabled)
        #expect(restart.target === controller)
        // `restartDaemon(_:)` is private, so resolve the selector by name
        // rather than via `#selector` (which can't reach private members).
        #expect(restart.action == NSSelectorFromString("restartDaemon:"))
    }

    // MARK: - Wiring helpers

    /// Build a real `MenuBarItemController` with lightweight, in-memory
    /// dependencies. `buildMenu` only reads `registry.wikis` (empty here) and
    /// `activityTracker.todayUsage` (no data on a fresh tracker), so none of
    /// the heavier session/engine machinery is exercised by the menu build.
    private func makeController() throws -> MenuBarItemController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-item-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let engine = try makeTestQueueEngine()
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })
        let sessionManager = SessionManager(
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: engine,
            extractionProvider: StubExtractionProvider(),
            pdf2mdScriptPathResolver: { nil })
        let registry = WikiRegistryClient(containerDirectory: dir)

        return MenuBarItemController(
            queueEngine: engine,
            activityTracker: QueueActivityTracker(),
            sessionManager: sessionManager,
            registry: registry,
            openWindowBridge: OpenWindowBridge())
    }
}

// MARK: - Minimal stubs (mirror PageDetailViewHostedTests)

@MainActor
private final class StubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(pdfData: Data, filename: String, onProgress: (@Sendable (String) -> Void)?) async throws -> String { "" }
}

private struct StubExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(wikiID: String, sourceID: PageID, backendOverride: ExtractionBackend?) async throws -> ExtractionResolution? { nil }
    func persistExtraction(wikiID: String, sourceID: PageID, markdown: String, backend: ExtractionBackend, modelVersion: String?, technique: String?) async throws {}
}

private func makeTestQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = StubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}
#endif

import Foundation
import Testing

@Suite("Cordis documentation contracts")
struct CordisDocumentationContractTests {
    @Test("design, progress, provenance, and pinned evidence are indexed")
    func documentationAndAttributionAreComplete() throws {
        let root = repositoryRoot()
        let planPath = "plans/cordis-swift-components.md"
        let progressPath = "progress/2026-08-18T033500Z-cordis-runtime-queue-migration.md"
        let plan = try String(
            contentsOf: root.appendingPathComponent(planPath),
            encoding: .utf8)
        let progress = try String(
            contentsOf: root.appendingPathComponent(progressPath),
            encoding: .utf8)
        let index = try String(
            contentsOf: root.appendingPathComponent("PLAN.md"),
            encoding: .utf8)

        #expect(index.contains("[`\(planPath)`](\(planPath))"))
        #expect(index.contains("[`\(progressPath)`](\(progressPath))"))
        #expect(plan.contains("**Provenance-Mode:** `clean-room behavior implementation`"))
        #expect(plan.contains("8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4"))
        #expect(plan.contains("6c210e5cdc10766190074d63ee35d6c32e4f39bd"))
        #expect(plan.contains("packages/core/tests/service.spec.ts"))
        #expect(plan.contains("packages/core/tests/fiber.spec.ts"))
        #expect(plan.contains("packages/core/tests/dispose.spec.ts"))
        #expect(plan.contains("Both references use the MIT License"))
        #expect(progress.contains("The final GLM re-review reported no remaining critical, high, or medium findings."))
        #expect(progress.contains("3,366 tests in 311 suites"))

        let extractionPlanPath = "plans/cordis-extraction-services.md"
        let extractionProgressPath = "progress/2026-08-19T150000Z-cordis-extraction-services.md"
        let extractionPlan = try String(
            contentsOf: root.appendingPathComponent(extractionPlanPath),
            encoding: .utf8)
        let extractionProgress = try String(
            contentsOf: root.appendingPathComponent(extractionProgressPath),
            encoding: .utf8)
        #expect(index.contains("[`\(extractionPlanPath)`](\(extractionPlanPath))"))
        #expect(index.contains("[`\(extractionProgressPath)`](\(extractionProgressPath))"))
        #expect(extractionPlan.contains("extraction.configuration-reader"))
        #expect(extractionPlan.contains("Logging remains outside Cordis"))
        #expect(extractionProgress.contains("ExtractionRuntimeAssembly"))

        let rendererPlanPath = "plans/cordis-renderer-services.md"
        let rendererProgressPath = "progress/2026-08-19T170000Z-cordis-renderer-services.md"
        let rendererPlan = try String(
            contentsOf: root.appendingPathComponent(rendererPlanPath),
            encoding: .utf8)
        let rendererProgress = try String(
            contentsOf: root.appendingPathComponent(rendererProgressPath),
            encoding: .utf8)
        #expect(index.contains("[`\(rendererPlanPath)`](\(rendererPlanPath))"))
        #expect(index.contains("[`\(rendererProgressPath)`](\(rendererProgressPath))"))
        for label in [
            "renderer.package-store-layout",
            "renderer.machine-index-store",
            "renderer.package-validator-factory",
            "renderer.resource-provider-factory",
            "renderer.bundled-package-source",
            "renderer.runtime",
            "renderer.services",
        ] {
            #expect(rendererPlan.contains(label))
        }
        #expect(rendererPlan.contains("`InstalledRendererHost` is the main-actor observation adapter"))
        #expect(rendererPlan.contains("SwiftUI views and settings models"))
        #expect(rendererPlan.contains("WebKit objects and active renderer sessions"))
        #expect(rendererPlan.contains("They never receive a `CordisContext`, `ActivationContext`, or `ServiceKey`"))
        #expect(rendererProgress.contains("RendererRuntimeAssembly"))
        #expect(rendererProgress.contains("RendererCompositionOwner"))

        let searchPlanPath = "plans/cordis-search-services.md"
        let searchProgressPath = "progress/2026-08-19T194500Z-cordis-search-services.md"
        let searchPlan = try String(
            contentsOf: root.appendingPathComponent(searchPlanPath),
            encoding: .utf8)
        let searchProgress = try String(
            contentsOf: root.appendingPathComponent(searchProgressPath),
            encoding: .utf8)
        #expect(index.contains("[`\(searchPlanPath)`](\(searchPlanPath))"))
        #expect(index.contains("[`\(searchProgressPath)`](\(searchProgressPath))"))
        for label in [
            "search.identity", "search.content-source", "search.change-stream-factory",
            "search.indexer", "search.runtime", "search.services",
        ] {
            #expect(searchPlan.contains(label))
        }
        #expect(searchPlan.contains("one private search root context"))
        #expect(searchPlan.contains("one child context"))
        #expect(searchPlan.contains("`WikiStore` and `WikiEventBus`"))
        #expect(searchPlan.contains("SQLite and GRDB connections, statements, transactions, and read pools"))
        #expect(searchPlan.contains("`WikiStoreModel`, `WikiSession`, and `SessionManager`"))
        #expect(searchProgress.contains("SearchRuntimeAssembly"))
        #expect(searchProgress.contains("SearchCompositionOwner"))
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

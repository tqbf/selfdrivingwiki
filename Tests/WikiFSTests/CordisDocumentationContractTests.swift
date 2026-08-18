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
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

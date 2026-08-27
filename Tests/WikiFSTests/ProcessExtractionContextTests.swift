import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSExtractorStore
@testable import WikiFSCore
import WikiFSTypes
import Cordis

@Suite("Process extraction context identity", .serialized, .timeLimit(.minutes(3)))
struct ProcessExtractionContextTests {
    @Test func fixedServicesAreSuppliedExactlyOncePerProcess() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            admissionOverride: AlwaysAdmitted())

        // Competing supplies must fail closed so no consumer can introduce a
        // second registry, executor, or catalog reader within this process.
        do {
            _ = try await context.cordisContext.supply(
                ExtractionServiceKeys.backends,
                value: ExtractionBackendRegistry())
            Issue.record("Expected duplicateSupply to reject a second registry")
        } catch {
            guard case CordisError.duplicateSupply = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test func membershipAdmissionTracksTheGeneratedPluginLifecycle() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(layout: environment.layout)
        #expect(await context.registry.containsRevision(environment.revision) == false)

        let applied = await context.reconcileNow()
        #expect(applied.appliedGeneration == 1)
        #expect(await context.registry.containsRevision(environment.revision))

        let writer = try ExtractorPackageCatalogWriter.testing(layout: environment.layout)
        _ = try await writer.replaceCatalog(expectedGeneration: 1, records: [])
        _ = await context.reconcileNow()
        #expect(await context.registry.containsRevision(environment.revision) == false)
    }

    @Test func separateAssembliesAreIndependentProcessGraphs() async throws {
        let first = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { first.cleanup() }
        let second = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { second.cleanup() }

        let contextA = try await ProcessExtractionContext.assemble(layout: first.layout)
        let contextB = try await ProcessExtractionContext.assemble(layout: second.layout)

        _ = await contextA.reconcileNow()
        _ = await contextB.reconcileNow()

        #expect(await contextA.registry.installedMatches(kind: .pdf).count == 1)
        #expect(await contextB.registry.installedMatches(kind: .pdf).count == 1)

        // Mutating A cannot leak into B: an app-profile registration is
        // invisible to the daemon-shaped assembly.
        let probeKey = ExtractionBackendKey(kind: .pdf, backendID: "process-a-probe")
        _ = try await contextA.registry.register(
            RegisteredExtractionBackend(key: probeKey) {
                .pdf(ExtractionPreparation(
                    extractor: ContextProbeExtractor(),
                    backend: .localPdf2md,
                    modelVersion: nil))
            })
        #expect(await contextA.registry.resolve(probeKey) != nil)
        #expect(await contextB.registry.resolve(probeKey) == nil)

        // Each context observes its own durable generation independently.
        let observationA = await contextA.observationSnapshot()
        let observationB = await contextB.observationSnapshot()
        #expect(observationA.appliedGeneration == 1)
        #expect(observationB.appliedGeneration == 1)
        #expect(observationA.hostedPlugins.count == 1)
        #expect(observationB.hostedPlugins.count == 1)
    }

    @Test func shutdownRemovesBuiltInAndInstalledRegistrations() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(layout: environment.layout)
        let input = ExtractionProcessInput(
            services: MutableExtractionServices(),
            readConfiguration: { ExtractionConfig() },
            readCredential: { _ in nil },
            resolveACP: { _ in nil },
            httpFetcher: FakeHTTPFetcher(responses: []),
            makeLocalExtractor: { ContextProbeExtractor() },
            packageContainerDirectory: environment.root,
            packageProcessRole: .test)
        let services = try await ProcessExtractionServices.assemble(context: context, input: input)
        _ = await context.reconcileNow()

        let builtInKey = ExtractionBackendKey(
            kind: .pdf,
            backendID: ExtractionBackend.localPdf2md.rawValue)
        #expect(await context.registry.resolve(builtInKey) != nil)
        #expect(await context.registry.containsRevision(environment.revision))

        await services.shutdown()

        #expect(await context.registry.resolve(builtInKey) == nil)
        #expect(await context.registry.containsRevision(environment.revision) == false)
        #expect(await context.registry.allKeys().isEmpty)
    }
}

private struct ContextProbeExtractor: MarkdownExtractor {
    var displayName: String { "probe" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "" }
}

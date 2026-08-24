#if os(macOS)
import CordisLoader
import Testing
@testable import WikiFSEngine

@Suite("Opaque profile lifetime", .serialized, .timeLimit(.minutes(1)))
struct ProfileLifetimeTests {
    @Test("shutdown is idempotent")
    func shutdownIsIdempotent() async throws {
        let disposals = ProfileProcessDisposalRecorder()
        let profile = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.processCatalog(
                includeAppServices: false,
                recorder: disposals),
            layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: false))]))
        let lifetime = ProfileLifetime(profile: profile)

        try await lifetime.shutdown()
        try await lifetime.shutdown()

        #expect(await disposals.count == 2)
    }

    @Test("shutdown rejects new child boot")
    func shutdownRejectsNewChildBoot() async throws {
        let disposals = ProfileProcessDisposalRecorder()
        let profile = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.processCatalog(
                includeAppServices: false,
                recorder: disposals),
            layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: false))]))
        let lifetime = ProfileLifetime(profile: profile)
        try await lifetime.shutdown()

        await #expect(throws: ProfileLifetimeError.shutdownStarted) {
            _ = try await lifetime.bootChild(catalog: try ProfileBootFixture.daemonCatalog(), layers: [])
        }
    }
}
#endif

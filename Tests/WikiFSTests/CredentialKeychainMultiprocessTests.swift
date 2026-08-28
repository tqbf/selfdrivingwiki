#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// OPT-IN real-Keychain coverage for the shared credential service
/// (`WIKIFS_KEYCHAIN_TESTS=1 swift test --filter CredentialKeychainMultiprocessTests`).
///
/// Skipped by default so `swift test` never persists test secrets: the
/// default suite set exercises the same contracts against
/// `InMemoryCredentialService` (`CredentialServiceContractTests`) and asserts
/// the physical mapping without touching Keychain
/// (`LegacyCredentialAdapterTests`). CI additionally lacks the production
/// `keychain-access-groups` entitlement, so the SIGNED app/daemon smoke
/// (plans/keychain-sharing.md §5.2) remains the production access-group gate;
/// the limitation is documented in plans/credential-service.md.
///
/// What this fixture adds when enabled: REAL SecItem round-trips through
/// `KeychainCredentialService` plus CROSS-PROCESS visibility — the `security`
/// CLI (a separate process) must see the item the test wrote, mirroring the
/// app-writes/daemon-reads shape (AC.9's physical substrate).
///
/// Cleanup discipline: the item is deleted in EVERY terminal path (the
/// deferred unset plus the success assertion), and the account name embeds a
/// UUID so reruns can never collide with prior runs or real credentials.
@Suite(
    .serialized,
    .timeLimit(.minutes(2)),
    .disabled(
        if: ProcessInfo.processInfo.environment["WIKIFS_KEYCHAIN_TESTS"] == nil,
        "Set WIKIFS_KEYCHAIN_TESTS=1 to run real-Keychain tests")
)
struct CredentialKeychainMultiprocessTests {

    @Test func parentAndHelperProcessRoundTripAUniqueItem() async throws {
        let service = KeychainCredentialService()

        // 0. ABSENCE is distinct from failure on the live keychain: a read
        //    of a never-written unique account throws .notConfigured —
        //    not a keychain status error.
        let absentReference = try CredentialReference(
            validating: "test.absent.\(UUID().uuidString.lowercased())")
        do {
            _ = try service.resolve(absentReference)
            Issue.record("expected notConfigured for an absent item")
        } catch CredentialStoreError.notConfigured {
            // expected — absence, not a Keychain failure
        } catch {
            Issue.record("unexpected error for absent item: \(error)")
        }
        // A unique reference under the shared credential service — never a
        // legacy location, never a real credential.
        let reference = try CredentialReference(
            validating: "test.multiprocess.\(UUID().uuidString.lowercased())")
        let location = CredentialLocations.location(for: reference)
        #expect(location.service == "org.sockpuppet.WikiFS.credentials")

        // 1. Parent writes through the service.
        try service.set("multiprocess-canary-\(reference.rawValue.suffix(8))", for: reference)
        defer { try? service.unset(reference) }

        // 2. Parent reads it back through the service.
        let resolved = try service.resolve(reference)
        #expect(resolved.value.contains("multiprocess-canary"))

        // 3. A HELPER PROCESS (the `security` CLI) sees the same item —
        //    cross-process Keychain visibility in the un-grouped test
        //    keychain.
        let seenByHelper = try await Task.detached(priority: .userInitiated) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = [
                "find-generic-password",
                "-s", location.service,
                "-a", location.account,
            ]
            // Non-blocking completion + timeout (repo #1051 discipline).
            let seen = try await withThrowingTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                        process.terminationHandler = { termination in
                            continuation.resume(returning: termination.terminationStatus == 0)
                        }
                        do {
                            try process.run()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(15))
                    if process.isRunning { process.terminate() }
                    return false
                }
                let result = try await group.next() ?? false
                group.cancelAll()
                return result
            }
            return seen
        }.value
        #expect(seenByHelper)

        // 4. Terminal cleanup — delete in the success path too (the defer
        //    covers throws/skips above).
        try service.unset(reference)
        #expect(service.describe(reference).isConfigured == false)
    }
}
#endif

import Foundation
import Testing
@testable import WikiFSCore

/// Tests for `DomainRegistrationPolicy` — the pure decision logic behind robust
/// File Provider domain registration (verify + bounded retry). The side effects
/// (`NSFileProviderManager.add`/`.domains()`/`signalEnumerator`) live in the app
/// layer's `FileProviderSpike`, which can't be unit-tested; THIS arithmetic
/// (registered? / retry? / failed?) is the extracted, tested seam.
struct DomainRegistrationPolicyTests {

    // MARK: - isRegistered

    @Test func registeredWhenIDPresent() {
        #expect(DomainRegistrationPolicy.isRegistered(domainIDs: ["A", "B", "C"], wikiID: "B"))
    }

    @Test func notRegisteredWhenIDAbsent() {
        #expect(!DomainRegistrationPolicy.isRegistered(domainIDs: ["A", "C"], wikiID: "B"))
    }

    @Test func notRegisteredAgainstEmptyList() {
        #expect(!DomainRegistrationPolicy.isRegistered(domainIDs: [], wikiID: "B"))
    }

    @Test func matchIsExactNotPrefix() {
        // ULIDs share prefixes; a partial match must NOT count as registered.
        #expect(!DomainRegistrationPolicy.isRegistered(domainIDs: ["01ABCDEF"], wikiID: "01AB"))
    }

    // MARK: - decide

    @Test func presentDomainIsRegisteredRegardlessOfAttempts() {
        #expect(DomainRegistrationPolicy.decide(domainPresent: true, attemptsMade: 1) == .registered)
        #expect(DomainRegistrationPolicy.decide(domainPresent: true, attemptsMade: 3) == .registered)
    }

    @Test func absentDomainRetriesWhileAttemptsRemain() {
        #expect(DomainRegistrationPolicy.decide(domainPresent: false, attemptsMade: 1) == .retry)
        #expect(DomainRegistrationPolicy.decide(domainPresent: false, attemptsMade: 2) == .retry)
    }

    @Test func absentDomainFailsAfterMaxAttempts() {
        #expect(
            DomainRegistrationPolicy.decide(
                domainPresent: false,
                attemptsMade: DomainRegistrationPolicy.maxAttempts
            ) == .failed
        )
    }

    /// Drive the same loop `FileProviderSpike.registerDomain` runs — a domain that
    /// only appears on the LAST allowed attempt must still resolve to `.registered`
    /// (the busy-daemon-self-heals case), never `.failed`.
    @Test func resolvesRegisteredOnFinalAttempt() {
        let appearsOnAttempt = DomainRegistrationPolicy.maxAttempts
        var outcome: DomainRegistrationPolicy.Decision?
        var attemptsMade = 0
        while attemptsMade < DomainRegistrationPolicy.maxAttempts {
            attemptsMade += 1
            let present = attemptsMade >= appearsOnAttempt
            let decision = DomainRegistrationPolicy.decide(domainPresent: present, attemptsMade: attemptsMade)
            if decision != .retry {
                outcome = decision
                break
            }
        }
        #expect(outcome == .registered)
    }

    /// A domain that never appears exhausts the bounded retries and ends `.failed`
    /// — a loud, detectable outcome, not an infinite spin.
    @Test func resolvesFailedWhenNeverAppears() {
        var outcome: DomainRegistrationPolicy.Decision?
        var attemptsMade = 0
        while attemptsMade < DomainRegistrationPolicy.maxAttempts {
            attemptsMade += 1
            let decision = DomainRegistrationPolicy.decide(domainPresent: false, attemptsMade: attemptsMade)
            if decision != .retry {
                outcome = decision
                break
            }
        }
        #expect(outcome == .failed)
    }

    @Test func maxAttemptsIsBoundedAndPositive() {
        #expect(DomainRegistrationPolicy.maxAttempts >= 1)
        #expect(DomainRegistrationPolicy.maxAttempts <= 5)
    }
}

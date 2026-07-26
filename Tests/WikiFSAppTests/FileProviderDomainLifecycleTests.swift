#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// Lifecycle tests for `FileProviderFacade`'s domain registration, driven through
/// the `FileProviderDomainService` seam so no live `fileproviderd` is involved.
///
/// These exist because of #919: `renameDomain` did a remove + re-add under a doc
/// comment calling it "cosmetic", and nothing could catch it — the facade called
/// `NSFileProviderManager` statics directly, so there was no observable to assert
/// against. The regression that matters is behavioural ("a rename tears down the
/// replica"), not structural, so the tests below assert on the *calls made*, with
/// `DomainRemovalReason` naming any illegitimate teardown in the failure message.
///
/// Serialized because the schema-migration flag lives in `UserDefaults`, which is
/// process-global: a pending migration makes `registerDomain` remove before it
/// adds, so tests that ran in parallel with the migration case would see its
/// teardowns. Each test declares the migration state it needs via `settled()`.
@MainActor
@Suite(.serialized)
struct FileProviderDomainLifecycleTests {

    /// Put the process in the "no migration pending" state — the steady state for
    /// every launch after the first. Without this, a fresh defaults domain reads
    /// version 0, `needsDomainMigration` is true, and `registerDomain` tears the
    /// domain down before re-adding it.
    private func settled() {
        UserDefaults.standard.set(
            FileProviderFacade.currentSchemaVersion, forKey: FileProviderFacade.schemaVersionKey)
    }

    /// Records every lifecycle call and models the daemon's one real behaviour
    /// that matters here: `add` is an upsert keyed by identifier, so re-adding an
    /// existing id REPLACES its display name rather than erroring or duplicating.
    ///
    /// Every stored property is mutated only inside `lock`, and no reference to
    /// that state escapes an accessor — that invariant is what the unchecked
    /// conformance rests on. It's needed because `FileProviderDomainService` is
    /// `Sendable` while a spy is mutable by definition.
    // swiftlint:disable:next unchecked_sendable
    private final class FakeDomainService: FileProviderDomainService, @unchecked Sendable {
        enum Call: Equatable {
            case add(id: String, displayName: String)
            case remove(id: String, reason: DomainRemovalReason)
            case domains
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var registered: [String: String] = [:]
        private var _addError: (any Error)?

        init(registered: [String: String] = [:]) {
            self.registered = registered
        }

        var calls: [Call] { lock.withLock { _calls } }
        /// Every removal that happened, with its stated reason.
        var removals: [(id: String, reason: DomainRemovalReason)] {
            calls.compactMap { if case let .remove(id, reason) = $0 { (id, reason) } else { nil } }
        }
        func name(of id: String) -> String? { lock.withLock { registered[id] } }

        /// Make `add` throw instead of applying — models e.g.
        /// `NSFileWriteFileExistsError` against a leftover replica.
        func failAdds(with error: any Error) { lock.withLock { _addError = error } }

        func add(id: String, displayName: String) async throws {
            try lock.withLock {
                _calls.append(.add(id: id, displayName: displayName))
                if let _addError { throw _addError }
                registered[id] = displayName
            }
        }

        func remove(id: String, reason: DomainRemovalReason) async throws {
            lock.withLock {
                _calls.append(.remove(id: id, reason: reason))
                registered[id] = nil
            }
        }

        func domains() async -> [RegisteredDomain] {
            lock.withLock {
                _calls.append(.domains)
                return registered.map { RegisteredDomain(id: $0.key, displayName: $0.value) }
            }
        }
    }

    private static let wikiID = "01HZZZWIKIONE"

    // MARK: - Rename

    /// THE #919 regression, stated directly. `remove` deletes the daemon's on-disk
    /// replica; a rename is a display-name change and must not touch it.
    @Test func renameNeverRemovesTheDomain() async {
        settled()
        let service = FakeDomainService(registered: [Self.wikiID: "Old Name"])
        let facade = FileProviderFacade(domainService: service)

        await facade.renameDomain(id: WikiID(rawValue: Self.wikiID), displayName: "New Name")

        #expect(
            service.removals.isEmpty,
            "rename tore down the domain, reason(s): \(service.removals.map(\.reason.rawValue))")
    }

    @Test func renameUpdatesTheDisplayNameForAStableIdentifier() async {
        settled()
        let service = FakeDomainService(registered: [Self.wikiID: "Old Name"])
        let facade = FileProviderFacade(domainService: service)

        await facade.renameDomain(id: WikiID(rawValue: Self.wikiID), displayName: "New Name")

        #expect(service.name(of: Self.wikiID) == "New Name")
    }

    /// A rename against a domain the daemon doesn't currently list must still end
    /// registered — `add` is the same call either way, so this path self-heals
    /// rather than silently doing nothing.
    @Test func renameOfAnUnregisteredDomainStillRegistersIt() async {
        settled()
        let service = FakeDomainService()
        let facade = FileProviderFacade(domainService: service)

        await facade.renameDomain(id: WikiID(rawValue: Self.wikiID), displayName: "New Name")

        #expect(service.name(of: Self.wikiID) == "New Name")
        #expect(service.removals.isEmpty)
    }

    /// The old remove-then-re-add ordering put the destructive step first and the
    /// fallible step second, so a failed re-add left the wiki unmounted with
    /// `activeWikiID`/`path` already cleared. With a single fallible call there is
    /// nothing to roll back: a failure must surface in `status` and leave the
    /// active-wiki state untouched.
    @Test func aFailedRenameSurfacesInStatusAndDoesNotClearTheActiveWiki() async {
        settled()
        let service = FakeDomainService(registered: [Self.wikiID: "Old Name"])
        service.failAdds(with: NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: nil))
        let facade = FileProviderFacade(domainService: service)
        await facade.activate(id: WikiID(rawValue: Self.wikiID), displayName: "Old Name")

        await facade.renameDomain(id: WikiID(rawValue: Self.wikiID), displayName: "New Name")

        #expect(facade.status.contains("Rename"))
        #expect(service.name(of: Self.wikiID) == "Old Name", "failed rename must not disturb the domain")
        #expect(service.removals.isEmpty)
    }

    // MARK: - Register

    /// `registerDomain` is deliberately add-if-absent: the presence check is what
    /// makes it idempotent while `registerAllDomains` races it. The consequence —
    /// and the trap that makes the naive #919 fix a silent no-op — is that it
    /// CANNOT rename. Pinned here so a future pass that tries to collapse
    /// `renameDomain` into `registerDomain` fails loudly instead of quietly
    /// breaking rename.
    @Test func registerDomainDoesNotRenameAnAlreadyPresentDomain() async {
        settled()
        let service = FakeDomainService(registered: [Self.wikiID: "Old Name"])
        let facade = FileProviderFacade(domainService: service)

        let ok = await facade.registerDomain(id: WikiID(rawValue: Self.wikiID), displayName: "Different Name")

        #expect(ok)
        #expect(
            service.name(of: Self.wikiID) == "Old Name",
            "registerDomain is add-if-absent — use renameDomain to change the display name")
    }

    @Test func registerDomainAddsAnAbsentDomain() async {
        settled()
        let service = FakeDomainService()
        let facade = FileProviderFacade(domainService: service)

        let ok = await facade.registerDomain(id: WikiID(rawValue: Self.wikiID), displayName: "Wiki One")

        #expect(ok)
        #expect(service.name(of: Self.wikiID) == "Wiki One")
    }

    // MARK: - Remove

    /// Deleting a wiki is one of the three legitimate teardowns, and it must say
    /// so — the reason is what lets a crash-report timeline tell a deliberate
    /// removal apart from an accidental one.
    @Test func deletingAWikiRemovesItsDomainWithTheDeletedReason() async {
        settled()
        let service = FakeDomainService(registered: [Self.wikiID: "Wiki One"])
        let facade = FileProviderFacade(domainService: service)

        await facade.removeDomain(id: WikiID(rawValue: Self.wikiID))

        #expect(service.removals.map(\.reason) == [.wikiDeleted])
        #expect(service.name(of: Self.wikiID) == nil)
    }

    @Test func schemaMigrationRemovesEveryDomainWithTheMigrationReason() async {
        let other = "01HZZZWIKITWO"
        let service = FakeDomainService(registered: [Self.wikiID: "One", other: "Two"])
        let facade = FileProviderFacade(domainService: service)
        // `migrateDomainsIfNeeded` is a one-shot keyed on a UserDefaults version;
        // clear it so this test drives the migration path rather than the no-op.
        UserDefaults.standard.removeObject(forKey: "FileProviderDomainSchemaVersion")

        await facade.migrateDomainsIfNeeded(wikiIDs: [WikiID(rawValue: Self.wikiID), WikiID(rawValue: other)])

        #expect(service.removals.allSatisfy { $0.reason == .schemaMigration })
        #expect(Set(service.removals.map(\.id)) == [Self.wikiID, other])
    }
}
#endif

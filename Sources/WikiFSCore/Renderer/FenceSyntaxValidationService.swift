import Foundation
import WikiFSMarkdown
import WikiFSTypes

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// pattern: Imperative Shell
// Reason: the service bridges the machine package store (filesystem +
// SQLite) to the pure FenceSyntaxValidator runner. Its decisions — which
// packages claim which aliases — are value based.

/// Package-driven, format-neutral save-time fence validation. The service
/// reads the installed-package snapshot from the machine index store, finds
/// packages whose descriptors declare fence claims with validation
/// contracts, and builds one ``FenceSyntaxValidator`` per package from the
/// declared (digest-pinned) assets. The host carries no format knowledge.
///
/// Skip semantics match the old nil-validator contract: when no claiming
/// package is installed, when safe mode suppresses it, or when an asset
/// cannot be read, validation returns nothing and callers proceed.
// The mutable caches are guarded by `lock` (NSLock); the layout is immutable.
// The @unchecked conformance is required only because the caches are var
// storage — every access path takes `lock` first.
// swiftlint:disable:next unchecked_sendable
public final class FenceSyntaxValidationService: FenceSyntaxValidating, @unchecked Sendable {
    private let layout: RendererPackageStoreLayout
    private let lock = NSLock()
    /// One runner per installed package/version, built on first use. The key
    /// is the validated descriptor identity, so a package update (new
    /// version) never reuses the previous engine.
    private var cachedRunners: [RendererPackageReservation: FenceSyntaxValidator?] = [:]

    private struct FenceClaimRecord: Sendable {
        let reservation: RendererPackageReservation
        let alias: RendererFenceAlias
        let validation: RendererFenceValidationDeclaration
        let expectedPackageHash: RendererSHA256Digest
    }

    public init(layout: RendererPackageStoreLayout) {
        self.layout = layout
    }

    /// Resolves the production machine store layout.
    public convenience init() throws {
        self.init(layout: try RendererPackageStoreLayout.production())
    }

    // MARK: - FenceSyntaxValidating

    public func fenceSaveWarning(for markdown: String) -> String? {
        guard let claims = resolveClaimingPackages() else { return nil }
        guard claims.isEmpty == false else { return nil }
        var warnings: [String] = []
        for claim in claims {
            // The cheap line scan runs first; a page without the claimed
            // fence pays nothing beyond the scan.
            let blocks = FenceSyntaxValidator.blocks(in: markdown, alias: claim.alias)
            guard blocks.isEmpty == false else { continue }
            guard let runner = runner(for: claim) else { continue }
            let invalid = runner.invalidBlocks(markdown: markdown, alias: claim.alias)
            let described = FenceSyntaxValidator.describe(alias: claim.alias, invalid: invalid)
            if !described.isEmpty {
                warnings.append(described)
            }
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    // MARK: - Claim resolution

    /// The aliases this markdown could have validated, and their claiming
    /// packages, from the installed-package snapshot. Empty when no claiming
    /// package is installed; nil when the store cannot be read (skip).
    public func claimedAliases(in markdown: String) -> [RendererFenceAlias] {
        guard let claims = resolveClaimingPackages() else { return [] }
        return claims
            .filter { FenceSyntaxValidator.blocks(in: markdown, alias: $0.alias).isEmpty == false }
            .map(\.alias)
    }

    /// True when at least one installed package declares a validation
    /// contract for `alias` — used for the `wikictl` skip notice.
    public func hasValidationContract(for alias: RendererFenceAlias) -> Bool {
        guard let claims = resolveClaimingPackages() else { return false }
        return claims.contains { $0.alias == alias }
    }

    public func validationSkipNotice(for markdown: String) -> String? {
        let present = FenceSyntaxValidator.richFenceAliases(in: markdown)
        guard present.isEmpty == false else { return nil }
        guard let claims = resolveClaimingPackages() else { return nil }
        let covered = Set(claims.map(\.alias))
        let uncovered = present.filter { covered.contains($0) == false }
        guard uncovered.isEmpty == false else { return nil }
        let names = uncovered.map(\.rawValue).joined(separator: ", ")
        return "validation skipped for \(names): no installed renderer package declares it"
    }

    private func resolveClaimingPackages() -> [FenceClaimRecord]? {
        lock.lock()
        defer { lock.unlock() }
        let store = RendererMachineIndexStore(layout: layout)
        let index: RendererMachineIndex
        do { index = try awaitSync(read: store) }
        catch {
            DebugLog.store("FenceSyntaxValidationService: machine index read failed: \(error)")
            return nil
        }
        // Safe mode suppresses every installed package; validation skips the
        // same way rendering falls back to Source.
        var records: [FenceClaimRecord] = []
        for record in index.records where record.state == .validated && record.isSafeModeSuppressed == false {
            let reservation = RendererPackageReservation(packageID: record.packageID, version: record.version)
            for descriptor in record.validatedDescriptors where record.isSafeModeSuppressed == false {
                for claim in descriptor.fenceClaims {
                    guard let validation = claim.validation else { continue }
                    records.append(FenceClaimRecord(
                        reservation: reservation,
                        alias: claim.alias,
                        validation: validation,
                        expectedPackageHash: record.expectedPackageHash))
                }
            }
        }
        return records
    }

    private func awaitSync(read store: RendererMachineIndexStore) throws -> RendererMachineIndex {
        // The machine store read is async; the save path is synchronous.
        // Bridge through a semaphore-backed continuation on a detached task
        // so a synchronous caller never parks the cooperative pool it runs
        // on (the same discipline as the store's own read pools).
        let box = ResultBox<RendererMachineIndex>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            do { box.set(.success(try await store.read())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        // A bounded wait: an unavailable store skips validation (nil
        // semantics) rather than hanging a save.
        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            throw FenceSyntaxValidationServiceError.storeReadTimedOut
        }
        return try box.get()
    }

    // MARK: - Runner construction

    private func runner(for claim: FenceClaimRecord) -> FenceSyntaxValidator? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedRunners[claim.reservation] {
            return cached
        }
        let runner = buildRunner(for: claim)
        cachedRunners[claim.reservation] = runner
        return runner
    }

    /// Reads the declared engine and wrapper assets from the installed
    /// payload (digest-pinned at install) and builds the runner. Any read or
    /// digest failure returns nil — the skip semantics callers rely on.
    ///
    /// Evaluation order is part of the package contract: the WRAPPER asset is
    /// evaluated first, then the engine asset. A wrapper may install engine
    /// prerequisites (a DOM/timer polyfill for an engine whose bundled
    /// dependencies capture DOM state at evaluation time) before the engine
    /// runs; the entry function is resolved after both, so it sees both.
    private func buildRunner(for claim: FenceClaimRecord) -> FenceSyntaxValidator? {
        let installedRoot = layout.packageURL(
            packageID: claim.reservation.packageID,
            version: claim.reservation.version)
        let provider: ValidatedRendererPackageResourceProvider
        do {
            provider = try ValidatedRendererPackageResourceProvider(
                packageID: claim.reservation.packageID,
                version: claim.reservation.version,
                expectedPackageHash: claim.expectedPackageHash,
                installedRoot: installedRoot,
                validator: RendererPackageValidator(
                    packageRoot: layout.root,
                    stagingRoot: layout.stagingRoot))
        } catch {
            DebugLog.store("FenceSyntaxValidationService: installed package revalidation failed: \(error)")
            return nil
        }
        func source(_ path: RendererRelativePath) -> String? {
            let url = RendererPackageScheme.url(
                packageID: claim.reservation.packageID,
                version: claim.reservation.version,
                path: path)
            do {
                let resource = try provider.resource(for: url)
                return String(decoding: resource.data, as: UTF8.self)
            } catch {
                DebugLog.store("FenceSyntaxValidationService: validation asset unreadable (\(path.rawValue)): \(error)")
                return nil
            }
        }
        guard let engine = source(claim.validation.engineAssetPath),
              let wrapper = source(claim.validation.wrapperAssetPath) else { return nil }
        return FenceSyntaxValidator(jsSources: [wrapper, engine], entryFunction: claim.validation.entryFunction)
    }
}

/// Bounded, non-pool-blocking result hand-off for the one-shot store read.
// The stored result is guarded by `lock` (NSLock); write once, read once.
// swiftlint:disable:next unchecked_sendable
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func set(_ value: Result<T, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }
    func get() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard case .success(let value)? = result else {
            if case .failure(let error)? = result { throw error }
            throw FenceSyntaxValidationServiceError.storeReadTimedOut
        }
        return value
    }
}

public enum FenceSyntaxValidationServiceError: Error, Equatable, Sendable {
    case storeReadTimedOut
}

import Foundation

// pattern: Imperative Shell

/// Main-actor ownership for the renderer machine projection. It fans an
/// authoritative reload only to live models and owns the reader's explicit
/// retirement path. No resource bus, File Provider, or search service enters
/// this type.
@MainActor
public final class RendererMachineEventSubscription {
    private let fanOut: RendererMachineModelFanOut
    private let reader: RendererMachineEventReader

    public init(
        journal: RendererMachineEventJournal,
        leases: RendererMachineLeaseRegistry,
        lease: RendererEventProcessLease,
        batchLimit: Int = RendererEventPolicy.phase3Default.orderedDrainBatchLimit
    ) {
        let fanOut = RendererMachineModelFanOut()
        self.fanOut = fanOut
        reader = RendererMachineEventReader(
            journal: journal,
            leases: leases,
            lease: lease,
            batchLimit: batchLimit,
            handler: { _ in await fanOut.reloadLiveModels() },
            retentionGapHandler: { await fanOut.reloadLiveModels() }
        )
    }

    /// Registers an already-open wiki projection. Calling this repeatedly for
    /// a model is idempotent; an unopened wiki has no registration and will
    /// read authoritative machine state when a future session creates it.
    public func register(_ model: WikiStoreModel) { fanOut.register(model) }

    public func unregister(_ model: WikiStoreModel) { fanOut.unregister(model) }

    /// Called by the payload-free machine wake observer after it matched an
    /// observed `RendererMachineScopeID` through `RendererMachineWakeRouting`.
    public func receiveWake() async throws { try await reader.receiveWake() }

    public func teardown(at now: RFC3339Timestamp) async throws {
        fanOut.removeAll()
        try await reader.cancel(at: now)
    }
}

@MainActor
private final class RendererMachineModelFanOut {
    private final class WeakModel {
        weak var value: WikiStoreModel?
        init(_ value: WikiStoreModel) { self.value = value }
    }

    private var models: [ObjectIdentifier: WeakModel] = [:]

    func register(_ model: WikiStoreModel) {
        models[ObjectIdentifier(model)] = WeakModel(model)
    }

    func unregister(_ model: WikiStoreModel) {
        models.removeValue(forKey: ObjectIdentifier(model))
    }

    func removeAll() {
        models.removeAll()
    }

    func reloadLiveModels() {
        models = models.filter { _, weakModel in
            guard let model = weakModel.value else { return false }
            model.reloadRendererMachineAvailability()
            return true
        }
    }
}

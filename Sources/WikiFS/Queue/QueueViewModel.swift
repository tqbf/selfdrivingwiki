import SwiftUI
import WikiFSCore
import WikiFSEngine

/// A view-model for the Activity window. Fetches snapshots from the engine
/// and updates on every queue event.
@MainActor
@Observable
final class QueueViewModel {
    var snapshot: QueueSnapshot = QueueSnapshot()
    private var streamTask: Task<Void, Never>?

    private weak var queueEngine: (any QueueEngineClient)?

    func attach(engine: any QueueEngineClient) {
        queueEngine = engine
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            // Initial snapshot.
            await self?.refresh()
            // Listen for updates.
            guard let self else { return }
            for await _ in engine.events {
                await self.refresh()
            }
        }
    }

    func detach() {
        streamTask?.cancel()
        streamTask = nil
        queueEngine = nil
    }

    func refresh() async {
        guard let engine = queueEngine else { return }
        snapshot = await engine.snapshot()
    }
}

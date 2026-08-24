#if canImport(WikiFSEngine)
import Foundation

actor DaemonCreationTaskRegistry {
    private var tasks: [UUID: Task<Data?, Never>] = [:]

    func insert(_ task: Task<Data?, Never>, id: UUID) {
        tasks[id] = task
    }

    func remove(id: UUID) {
        tasks.removeValue(forKey: id)
    }

    func cancelAndWait() async {
        let active = Array(tasks.values)
        tasks.removeAll()
        for task in active { task.cancel() }
        for task in active { _ = await task.value }
    }
}
#endif

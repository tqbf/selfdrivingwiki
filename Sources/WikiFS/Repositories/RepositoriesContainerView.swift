// pattern: Imperative Shell
import SwiftUI
import WikiFSCore
import WikiFSEngine

/// The repository section of the redesigned sidebar. Repository metadata is a
/// model projection; every expensive or privileged operation is an XPC-backed
/// queue request owned by `wikid`.
struct RepositoriesContainerView: View {
    @Bindable var store: WikiStoreModel
    let session: WikiSession

    @State private var showingAddRepository = false

    var body: some View {
        Group {
            if store.trackedRepositories.isEmpty {
                ContentUnavailableView {
                    Label("No Repositories", systemImage: "folder.badge.gearshape")
                } description: {
                    Text("Add a repository to let the daemon track and update this wiki.")
                } actions: {
                    Button("Add Repository", systemImage: "plus") {
                        showingAddRepository = true
                    }
                }
            } else {
                List(store.trackedRepositories) { repository in
                    RepositoryRow(
                        repository: repository,
                        enqueue: { action in
                            enqueue(action, for: repository)
                        },
                        updateConfigurationError: updateConfigurationError
                    )
                }
                .listStyle(.sidebar)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Repository", systemImage: "plus") {
                            showingAddRepository = true
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddRepository) {
            AddRepositorySheet { input in
                guard let repository = store.addTrackedRepository(remoteInput: input) else { return false }
                enqueue(.clone, for: repository)
                return true
            }
        }
    }

    private func enqueue(_ action: RepositoryWorkAction, for repository: TrackedRepo) {
        DebugLog.ingest("Repository action tapped action=\(action.rawValue) repo=\(repository.id.rawValue) canUpdate=\(repository.canRequestUpdate) drifted=\(repository.isDrifted)")
        if action == .update, let error = updateConfigurationError {
            DebugLog.ingest("RepositoriesContainerView refused update for \(repository.id.rawValue): \(error)")
            return
        }
        Task {
            do {
                let request = QueueItemRequest(
                    queue: .ingestion,
                    wikiID: session.wikiID,
                    payload: QueueItemPayload(
                        sourceIDs: [],
                        repositoryWork: RepositoryWorkRequest(repositoryID: repository.id, action: action)))
                _ = try await session.queueEngine.enqueue(request)
            } catch {
                DebugLog.ingest("RepositoriesContainerView failed to enqueue \(action.rawValue) for \(repository.id.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private var updateConfigurationError: String? {
        let directory = DebugLog.trying("resolve app group container", operation: {
            try DatabaseLocation.appGroupContainerDirectory()
        }) ?? FileManager.default.temporaryDirectory
        let config = AgentProvidersConfig.loadOrSeed(from: directory)
        return config.isRepositoryUpdateConfigured() ? nil : config.agentOperationConfigurationError(
            forStages: [ACPIngestStage.planner.rawValue])
    }
}

private struct RepositoryRow: View {
    let repository: TrackedRepo
    let enqueue: (RepositoryWorkAction) -> Void
    let updateConfigurationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(repository.name)
                .font(.headline)
            Text(repositoryStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
                    enqueue(.fetch)
                }
                .buttonStyle(.borderless)
                Button("Update", systemImage: "arrow.down.doc") {
                    enqueue(.update)
                }
                .buttonStyle(.borderless)
                .disabled(!repository.canRequestUpdate || updateConfigurationError != nil)
                .help(updateConfigurationError ?? "Update this wiki from the repository")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .onAppear {
            DebugLog.ingest("Repository row displayed repo=\(repository.id.rawValue) canUpdate=\(repository.canRequestUpdate) drifted=\(repository.isDrifted) configurationError=\(updateConfigurationError ?? "nil")")
        }
    }

    private var repositoryStatus: String {
        guard let branch = repository.branch else { return "Waiting for initial clone" }
        if repository.isDrifted {
            return "\(branch) · \(repository.shortHead) has updates"
        }
        return "\(branch) · up to date"
    }
}

private struct AddRepositorySheet: View {
    let addRepository: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @FocusState private var isRemoteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Repository")
                .font(.title2)
            Text("The daemon will clone and track this repository for the current wiki.")
                .foregroundStyle(.secondary)
            TextField("Repository URL", text: $remote)
                .textFieldStyle(.roundedBorder)
                .focused($isRemoteFocused)
                .onSubmit(add)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 420)
        .onAppear { isRemoteFocused = true }
    }

    private func add() {
        if addRepository(remote) {
            dismiss()
        }
    }
}

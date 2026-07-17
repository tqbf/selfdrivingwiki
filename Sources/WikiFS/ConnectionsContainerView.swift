import SwiftUI
import WikiFSCore

/// The **Connections** sidebar section: a provider-grouped tree where each
/// provider (Zotero, Folder) is a disclosure parent and configured connections
/// are its children. This mirrors the bookmarks tree pattern but simpler — no
/// drag-reorder, no nesting beyond one level.
///
/// Each provider row has an **＋** button that creates a new unconfigured
/// connection of that provider kind and opens its config tab. Clicking a
/// connection opens its workspace/config tab. The tree reads from the per-wiki
/// `WikiStoreModel.connections` list (backed by the SQLite `connections` table),
/// so it updates observably after a save or delete.
struct ConnectionsContainerView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(ProviderRegistry.addable) { manifest in
                    providerSection(manifest)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var header: some View {
        HStack {
            Text("Connections")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Provider section

    @ViewBuilder
    private func providerSection(_ manifest: ProviderManifest) -> some View {
        let children = connections(for: manifest.id)
        DisclosureGroup(isExpanded: sectionBinding(for: manifest.id)) {
            ForEach(children) { connection in
                connectionRow(connection, manifest: manifest)
            }
        } label: {
            providerHeader(manifest, count: children.count)
        }
    }

    private func providerHeader(_ manifest: ProviderManifest, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: manifest.icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(manifest.displayName).font(.body)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            // Inline add button on the provider row — matches the bookmarks
            // header pattern (compact + on the trailing edge).
            Button {
                addConnection(providerID: manifest.id)
            } label: {
                Image(systemName: "plus")
                    .font(.callout)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add \(manifest.displayName) Connection")
        }
    }

    // MARK: - Connection row

    private func connectionRow(_ connection: Connection, manifest: ProviderManifest) -> some View {
        Button {
            store.openTab(.connection(connection.id), title: connection.label)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isConfigured(connection)
                      ? "circle.fill"
                      : "circle.dashed")
                    .font(.caption2)
                    .foregroundStyle(isConfigured(connection) ? .green : .secondary)
                    .frame(width: 18)
                Text(connection.label).font(.body)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                store.deleteConnection(id: connection.id)
            }
        }
    }

    // MARK: - Helpers

    private func connections(for providerID: String) -> [Connection] {
        store.connections.filter { $0.providerID == providerID }
    }

    private func isConfigured(_ connection: Connection) -> Bool {
        switch connection.providerID {
        case ZoteroConnection.providerID:
            let apiKey = store.secret(for: connection, field: ZoteroConnection.apiKeyField)
            return ZoteroConnection.isConfigured(connection, apiKey: apiKey)
        default:
            return false
        }
    }

    /// Create a new connection for `providerID`, persist it, and open its tab
    /// in the config form (unconfigured — the user enters credentials).
    private func addConnection(providerID: String) {
        guard let connection = store.createConnection(providerID: providerID) else { return }
        store.openTab(.connection(connection.id), title: connection.label)
    }

    // MARK: - Section expansion state

    @State private var expandedSections: Set<String> = Set(ProviderRegistry.addable.map(\.id))

    private func sectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedSections.insert(id) }
                else { expandedSections.remove(id) }
            }
        )
    }
}

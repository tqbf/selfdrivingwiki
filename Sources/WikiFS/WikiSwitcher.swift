import SwiftUI
import WikiFSCore

/// The wiki switcher: a sidebar header `Menu` showing the active wiki's name
/// (like Notes' account header), listing every wiki to select between them, with
/// "New Wiki…", Rename, and Delete affordances. Each wiki is an independent
/// knowledge base (its own DB + File Provider domain), so this is the top-level
/// container switch — placed above navigation, per the macOS layout formula.
///
/// `.headline` gives the active name prominence over the `.caption`-styled
/// section headers and `.body` rows below it, without hardcoding sizes.
struct WikiSwitcher: View {
    @Bindable var manager: WikiManager

    @State private var newWikiName = ""
    @State private var showingNewWikiSheet = false
    @State private var renameTarget: WikiDescriptor?
    @State private var renameText = ""
    @State private var deleteTarget: WikiDescriptor?

    var body: some View {
        Menu {
            ForEach(manager.wikis) { wiki in
                Button {
                    manager.select(wiki.id)
                } label: {
                    Label(wiki.displayName, systemImage: checkmark(for: wiki))
                }
            }

            Divider()

            Button("New Wiki…", systemImage: "plus") {
                newWikiName = ""
                showingNewWikiSheet = true
            }

            if let active = activeDescriptor {
                Divider()
                Button("Rename “\(active.displayName)”…", systemImage: "pencil") {
                    renameText = active.displayName
                    renameTarget = active
                }
                Button("Delete “\(active.displayName)”…", systemImage: "trash", role: .destructive) {
                    deleteTarget = active
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(activeDescriptor?.displayName ?? "No Wiki")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .help("Switch between wikis, or create a new one")
        .sheet(isPresented: $showingNewWikiSheet) {
            NewWikiSheet(name: $newWikiName) { name in
                Task { await manager.createWiki(displayName: name) }
            }
        }
        .alert("Rename Wiki", isPresented: renamePresented, presenting: renameTarget) { target in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                manager.renameWiki(id: target.id, to: renameText)
                renameTarget = nil
            }
        }
        .alert("Delete Wiki?", isPresented: deletePresented, presenting: deleteTarget) { target in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                Task { await manager.deleteWiki(id: target.id) }
                deleteTarget = nil
            }
        } message: { target in
            Text("“\(target.displayName)” and all its pages, files, and its filesystem mount will be permanently deleted. This cannot be undone.")
        }
    }

    private var activeDescriptor: WikiDescriptor? {
        guard let id = manager.activeWikiID else { return nil }
        return manager.wikis.first { $0.id == id }
    }

    private func checkmark(for wiki: WikiDescriptor) -> String {
        wiki.id == manager.activeWikiID ? "checkmark" : ""
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
}

/// A small sheet to name a new wiki. Kept separate so the create flow has a
/// proper text field with Cancel/Create instead of cramming a `TextField` into
/// an alert (alerts can't validate-while-typing cleanly on macOS).
private struct NewWikiSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Wiki")
                .font(.headline)

            TextField("Wiki name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(create)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

import SwiftUI
import AppKit
import WikiFSCore

/// The wiki switcher: a sidebar header `Menu` showing the active wiki's name
/// (like Notes' account header), listing every wiki to select between them, with
/// "New Wiki…", Rename, and Delete affordances. Each wiki is an independent
/// knowledge base (its own DB + File Provider domain), so this is the top-level
/// container switch — placed above navigation, per the macOS layout formula.
///
/// `.headline` gives the active name prominence over the `.caption`-styled
/// section headers and `.body` rows below it, without hardcoding sizes.
///
/// Default click opens a new window (`openWindow(value:)`) or focuses an existing
/// one — the Safari/Xcode "open in new window" pattern. Option+click switches
/// the current window's wiki in place (releases old session, resolves new one in
/// the same window), via `registry.select` which sets `activeWikiID`; the
/// frontmost window's `RootScene` observes that and swaps its session.
struct WikiSwitcher: View {
    @Bindable var registry: WikiRegistryClient
    @Environment(\.openWindow) private var openWindow

    @State private var newWikiName = ""
    @State private var showingNewWikiSheet = false
    @State private var renameTarget: WikiDescriptor?
    @State private var renameText = ""
    @State private var deleteTarget: WikiDescriptor?
    @State private var importSourceURL: URL?
    @State private var importWikiName = ""
    @State private var failureMessage: String?

    var body: some View {
        Menu {
            ForEach(registry.wikis) { wiki in
                Button {
                    if NSEvent.modifierFlags.contains(.option) {
                        // Option+click: switch THIS window's wiki in place
                        // (release old session, open new one in the same
                        // window). `registry.select` sets `activeWikiID`;
                        // the frontmost `RootScene` observes it and swaps.
                        registry.select(wiki.id)
                    } else {
                        // Default: open a new window (or focus existing —
                        // `WindowGroup(for:)` deduplicates by `==`).
                        openWindow(value: wiki.id)
                    }
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
                Button("Export “\(active.displayName)”…", systemImage: "square.and.arrow.up") {
                    exportWiki(active)
                }
                Button("Delete “\(active.displayName)”…", systemImage: "trash", role: .destructive) {
                    deleteTarget = active
                }
            }

            Divider()

            Button("Import Wiki Backup…", systemImage: "square.and.arrow.down") {
                importWiki()
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
                Task { await registry.createWiki(displayName: name) }
            }
        }
        .alert("Rename Wiki", isPresented: renamePresented, presenting: renameTarget) { target in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                Task { await registry.renameWiki(id: target.id, to: renameText) }
                renameTarget = nil
            }
        }
        .sheet(isPresented: importPresented) {
            ImportWikiSheet(name: $importWikiName) { name in
                guard let sourceURL = importSourceURL else { return }
                Task {
                    do {
                        _ = try await registry.importWiki(from: sourceURL, displayName: name)
                    } catch {
                        failureMessage = String(describing: error)
                    }
                }
            }
        }
        .alert("Delete Wiki?", isPresented: deletePresented, presenting: deleteTarget) { target in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                Task { await registry.deleteWiki(id: target.id) }
                deleteTarget = nil
            }
        } message: { target in
            Text("“\(target.displayName)” and all its pages, files, and its filesystem mount will be permanently deleted. This cannot be undone.")
        }
        .alert("Wiki Operation Failed", isPresented: failurePresented) {
            Button("OK", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "An unknown error occurred.")
        }
    }

    private var activeDescriptor: WikiDescriptor? {
        guard let id = registry.activeWikiID else { return nil }
        return registry.wikis.first { $0.id == id }
    }

    private func checkmark(for wiki: WikiDescriptor) -> String {
        wiki.id == registry.activeWikiID ? "checkmark" : ""
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var importPresented: Binding<Bool> {
        Binding(
            get: { importSourceURL != nil },
            set: {
                if !$0 {
                    importSourceURL = nil
                    importWikiName = ""
                }
            }
        )
    }

    private var failurePresented: Binding<Bool> {
        Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })
    }

    private func exportWiki(_ wiki: WikiDescriptor) {
        guard let destinationURL = WikiFilePanels.exportURL(defaultName: wiki.displayName) else { return }
        do {
            try registry.exportWiki(id: wiki.id, to: destinationURL)
        } catch {
            failureMessage = String(describing: error)
        }
    }

    private func importWiki() {
        guard let sourceURL = WikiFilePanels.importURL() else { return }
        importSourceURL = sourceURL
        importWikiName = sourceURL.deletingPathExtension().lastPathComponent
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

/// Names a restored wiki after the user chooses a SQLite backup. The source file
/// already exists; this sheet only asks for the new display name.
private struct ImportWikiSheet: View {
    @Binding var name: String
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Wiki Backup")
                .font(.headline)

            TextField("Wiki name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(importBackup)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: importBackup)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func importBackup() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onImport(trimmed)
        dismiss()
    }
}

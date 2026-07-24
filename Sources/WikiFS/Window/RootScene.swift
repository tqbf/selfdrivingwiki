import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Per-window scene view for multi-window UI (`plans/multi-window-ui.md`
/// Phase 2b). Instantiated inside both the single-identity main `WindowGroup`
/// (launch) and the value-driven `WindowGroup(for: String.self)` (additional
/// wiki windows opened from the switcher).
///
/// Each `RootScene` resolves (or creates) its own `WikiSession` via the shared
/// `SessionManager`, owns per-window `scenePhase` (flush-on-background +
/// search-index backfill), owns the vacuum confirm alert, and releases its
/// session on `.onDisappear` (best-effort — macOS may not call this on close).
///
/// **Launch path:** the main window starts with `wikiID == nil`. `WikiFSApp`'s
/// `.task` calls `registry.activateMostRecent()`, which sets
/// `registry.activeWikiID`; the `.onChange` below adopts it, then the session
/// resolves via the `else if let wikiID` branch.
///
/// **Additional window path:** `WindowGroup(for: String.self)` passes the wiki
/// ID via the binding; the session resolves immediately via the same branch.
///
/// **In-window switch (Option+click):** `WikiSwitcher` calls
/// `registry.select(id)`, setting `activeWikiID`. Only the frontmost window
/// (`isSceneActive == true`) responds by releasing its old session and adopting
/// the new wiki ID in place — the Safari/Xcode pattern.
struct RootScene: View {
    /// The wiki ID for this window. `nil` before the MRU wiki is resolved at
    /// launch (the main window receives its ID from
    /// `registry.activeWikiID` after `activateMostRecent()`). Additional
    /// windows receive their ID from `WindowGroup(for: String.self)`'s
    /// binding.
    @State var wikiID: String?
    @Bindable var registry: WikiRegistryClient
    @Bindable var sessionManager: SessionManager
    let fileProvider: FileProviderFacade

    @State private var session: WikiSession?
    @State private var isSceneActive = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session {
                RootView(session: session, registry: registry, fileProvider: fileProvider)
                    .alert(
                        "Vacuum Orphaned Storage",
                        isPresented: Binding(
                            get: { session.pendingVacuumAll != nil },
                            set: { if !$0 { session.pendingVacuumAll = nil } }
                        ),
                        presenting: session.pendingVacuumAll
                    ) { report in
                        if report.isEmpty {
                            Button("OK", role: .cancel) {}
                        } else {
                            Button("Cancel", role: .cancel) {}
                            Button("Vacuum", role: .destructive) { session.applyVacuumAll() }
                        }
                    } message: { report in
                        Text(report.alertMessage)
                    }
            } else if let wikiID {
                // The wiki ID is known but the session isn't resolved yet, OR
                // the store failed to open (issue #881 — no in-memory fallback).
                // Show a user-visible error view instead of silently degrading
                // to an empty wiki, so the user understands their data isn't gone.
                if let errorMessage = sessionManager.openError(for: wikiID) {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text("Couldn’t Open Wiki")
                            .font(.title2.bold())
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 420)
                        HStack {
                            Button("Retry") {
                                sessionManager.clearOpenError(for: wikiID)
                                session = nil
                                resolveSession(for: wikiID)
                            }
                            Button("Reveal Database") {
                                let dbURL = sessionManager.containerDirectory
                                    .appendingPathComponent("\(wikiID).sqlite", isDirectory: false)
                                NSWorkspace.shared.activateFileViewerSelecting([dbURL])
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Opening wiki…")
                        .onAppear { resolveSession(for: wikiID) }
                        .onAppear {
                            DebugLog.tabs("RootScene [Opening wiki…]: wikiID=\(wikiID)")
                        }
                }
            } else {
                // No wiki ID from the WindowGroup binding AND no activeWikiID
                // adoption yet. This happens when the main WindowGroup creates
                // a RootScene before activateMostRecent() runs, or when state
                // restoration opens an extra main window. Try to adopt the
                // activeWikiID immediately — if it's already set, use it.
                ContentUnavailableView {
                    Label("No Wikis", systemImage: "books.vertical")
                } description: {
                    Text("Create a wiki to get started.")
                } actions: {
                    Button("New Wiki", systemImage: "plus") {
                        Task { await registry.createWiki(displayName: "My Wiki") }
                    }
                }
                .onAppear {
                    DebugLog.tabs("RootScene [No Wikis]: wikiID=nil session=nil registry.wikis.count=\(registry.wikis.count) activeWikiID=\(registry.activeWikiID ?? "nil") isSceneActive=\(isSceneActive)")
                    // Only adopt activeWikiID for the main launch window (which
                    // starts with wikiID==nil from the single-identity WindowGroup).
                    // Wiki windows (from WindowGroup(for: String.self)) should receive
                    // their ID from the binding — if they're nil here, it's a state-
                    // restoration edge case; adopt activeWikiID as a fallback.
                    if wikiID == nil, let activeID = registry.activeWikiID {
                        DebugLog.tabs("RootScene [No Wikis]: adopting activeWikiID=\(activeID)")
                        wikiID = activeID
                    } else if wikiID == nil, registry.activeWikiID == nil, !registry.wikis.isEmpty {
                        // The main WindowGroup's .task hasn't run yet (or this
                        // is a state-restored wiki window). Trigger activateMostRecent
                        // so activeWikiID gets set, which our onChange will adopt.
                        DebugLog.tabs("RootScene [No Wikis]: activating most recent")
                        registry.activateMostRecent()
                    }
                }
            }
        }
        // Tag this window's NSWindow.identifier with its wiki ID so the menu
        // bar can find and focus an already-open wiki window instead of
        // spawning a duplicate (see WindowIdentifierTagger).
        .background(WindowIdentifierTagger(wikiID: wikiID))
        .onAppear {
            DebugLog.tabs("RootScene body onAppear: wikiID=\(wikiID ?? "nil") session=\(session != nil ? "set" : "nil")")
        }
        .onChange(of: wikiID) { old, new in
            DebugLog.tabs("RootScene wikiID changed: old=\(old ?? "nil") new=\(new ?? "nil")")
        }
        // Observe activeWikiID for two purposes:
        // 1. Launch: activateMostRecent() sets activeWikiID → adopt it as
        //    our wikiID (this fires before scenePhase becomes .active, so
        //    we don't gate on isSceneActive for the nil→non-nil case).
        // 2. Option+click in-window switch: WikiSwitcher calls
        //    registry.select(id), setting activeWikiID. Only the frontmost
        //    window (isSceneActive == true) responds — other windows ignore
        //    it, preventing two windows from fighting over the same wiki.
        .onChange(of: registry.activeWikiID) { _, newID in
            guard wikiID != newID else { return }
            if wikiID == nil {
                // Launch path: main window adopts the MRU wiki.
                wikiID = newID
            } else if isSceneActive, let newID {
                // In-window switch (Option+click): release old session,
                // adopt new ID, resolve new session.
                if let oldID = wikiID {
                    sessionManager.releaseSession(for: oldID)
                    fileProvider.unsubscribeBus(for: oldID)
                }
                wikiID = newID
                session = nil
                resolveSession(for: newID)
                // Keep frontmost tracking accurate — scenePhase won't
                // re-emit `.active` on an in-window content swap, so we
                // must update it here. Without this, VacuumCommands
                // resolves the released session and silently no-ops.
                sessionManager.frontmostWikiID = newID
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session?.store.flushPendingSaves() }
            isSceneActive = (phase == .active)
            // Track frontmost window for VacuumCommands (scene-level .commands).
            if phase == .active, let wikiID {
                sessionManager.frontmostWikiID = wikiID
            }
            if phase == .active { Task { await session?.upgradeSearchIndex() } }
        }
        .onDisappear {
            // Release the session when the window closes — but only if the
            // queue engine has no pending/running work for this wiki. If
            // extraction or ingestion is in progress, the session must stay
            // alive so the worker can access the store + launcher.
            // Note: macOS may not call .onDisappear on window close —
            // unreleased sessions linger harmlessly in the SessionManager
            // cache and are drained by
            // AppDelegate.applicationWillResignActive →
            // flushAllSessions() on app background (plan R3).
            if let wikiID {
                Task {
                    let hasWork = await session?.queueEngine.hasActiveWork(for: wikiID) ?? false
                    if !hasWork {
                        sessionManager.releaseSession(for: wikiID)
                        fileProvider.unsubscribeBus(for: wikiID)
                    }
                }
            }
        }
    }

    /// Get-or-create the session for `wikiID` via the shared `SessionManager`,
    /// wire the File Provider bus subscription, activate the FP domain, and
    /// reap stale workspaces. Guarded by `session == nil` so calling it twice
    /// is a no-op.
    ///
    /// Runs in a `Task` (issue #477) so the `ProgressView("Opening wiki…")`
    /// spinner can animate while the synchronous store init + model reloads
    /// execute. The `Task.yield()` between reload phases lets the main run
    /// loop paint between batches of SQLite work.
    private func resolveSession(for wikiID: String) {
        guard session == nil else { return }
        guard let descriptor = registry.wikis.first(where: { $0.id == wikiID }) else { return }
        Task { @MainActor in
            // Yield first so the spinner paints before the store opens.
            await Task.yield()
            guard session == nil else { return }  // re-check after suspension
            // `session(for:)` throws when the on-disk store can't be opened
            // (issue #881). SessionManager records the error so the error
            // branch above renders; `session` stays nil.
            let resolved: WikiSession
            do {
                resolved = try sessionManager.session(for: wikiID, descriptor: descriptor)
            } catch {
                return
            }
            session = resolved
            // Wire the File Provider bus subscription for this wiki's session.
            fileProvider.subscribeBus(for: wikiID, bus: resolved.store.eventBus)
            Task { await fileProvider.activate(id: descriptor.id, displayName: descriptor.displayName) }
            // Reap stale workspaces for this wiki.
            _ = try? resolved.store.reapStaleWorkspaces(ttl: 86_400)
        }
    }
}

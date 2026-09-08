import Foundation
import WikiFSCore
import WikiFSEngine

// MARK: - Index

/// Indexed display names for the target IDs the job navigator resolves
/// (source filenames, page titles).
///
/// **Why this exists (M2):** the navigator's precompute pass used to resolve
/// every visible item's target IDs with `store.sources.first { … }` /
/// `store.summaries.first { … }` linear scans — O(items × targets × pages) on
/// the main actor for EVERY queue event, because each event refreshes the
/// snapshot and re-renders the sidebar. One index per live wiki session turns
/// that into a single O(sources + pages) pass per render plus O(targets)
/// dictionary lookups per item.
///
/// **First-match semantics are load-bearing:** the replaced scans resolved a
/// duplicated ID to the FIRST matching row in store order. `record*` keeps
/// that contract — a later duplicate never overwrites an earlier entry — so
/// the index and the linear scans agree in every case, including stores that
/// (defensively) contain duplicate rows.
///
/// Pure value type: built from plain `(id, name)` pairs so the parity rules
/// are unit-testable without a live `WikiStoreModel`, and the
/// observation-crash workaround is preserved — the caller snapshots the
/// observable `sources`/`summaries` arrays into this index inside
/// `buildRowDisplayData` (sidebar level), and row bodies keep reading plain
/// values only.
struct QueueTargetNameIndex: Equatable, Sendable {
    private var sourceNames: [SourceID: String] = [:]
    private var pageTitles: [PageID: String] = [:]

    init() {}

    /// Record `name` for `sourceID` unless an earlier row already claimed the
    /// ID (first-match semantics — see the type docs).
    mutating func recordSource(_ sourceID: SourceID, name: String) {
        if sourceNames[sourceID] == nil {
            sourceNames[sourceID] = name
        }
    }

    /// Record `title` for `pageID` unless an earlier row already claimed the
    /// ID (first-match semantics — see the type docs).
    mutating func recordPage(_ pageID: PageID, title: String) {
        if pageTitles[pageID] == nil {
            pageTitles[pageID] = title
        }
    }

    /// The source's display filename, or `nil` when it no longer resolves.
    /// Membership (`!= nil`) is also the "target still exists" check the
    /// inventory's navigation actions use.
    func sourceName(_ sourceID: SourceID) -> String? {
        sourceNames[sourceID]
    }

    /// The page's current title, or `nil` when it no longer resolves.
    func pageTitle(_ pageID: PageID) -> String? {
        pageTitles[pageID]
    }
}

// MARK: - Per-item resolution

/// One item's resolved target display names, in payload order.
struct QueueItemDisplayNames: Equatable, Sendable {
    /// Resolvable names in payload order; IDs that no longer resolve are
    /// dropped — identical to the linear-scan lookups this replaces, and
    /// load-bearing for the row-title fallbacks ("3 sources", "Lint 3 pages").
    let names: [String]
    /// The navigator's target list (title tooltip). Whole-wiki lint collapses
    /// to the "Entire wiki" marker; otherwise it equals `names`.
    let targets: [String]
}

extension QueueTargetNameIndex {
    /// Resolve one item's payload target names through the index — the same
    /// result the pre-index per-item linear scans produced, in O(targets)
    /// instead of O(targets × pages/sources).
    ///
    /// Lint payloads resolve page titles; everything else resolves source
    /// filenames. A lint payload with an EMPTY page-ID list is whole-wiki: it
    /// yields the "Entire wiki" marker rather than an empty list.
    func displayNames(for item: QueueItem) -> QueueItemDisplayNames {
        if let pageIDs = item.payload.lintPageIDs {
            let titles = pageIDs.compactMap { pageTitle($0) }
            return QueueItemDisplayNames(
                names: titles,
                targets: pageIDs.isEmpty ? ["Entire wiki"] : titles)
        }
        let resolved = item.payload.sourceIDs.compactMap { sourceName($0) }
        return QueueItemDisplayNames(names: resolved, targets: resolved)
    }
}

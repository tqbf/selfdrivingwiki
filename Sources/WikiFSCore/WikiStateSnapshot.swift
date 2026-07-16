import Foundation

/// A LIVE snapshot of one wiki's CURRENT state, gathered from the active store at
/// operation-click time and injected into the agent operation prompt
/// (`plans/llm-wiki.md` Phase D — "fewer orientation turns").
///
/// **Why this exists.** On the live gate, an Ingest run burned multiple turns
/// "understanding the structure of the wiki" — `wikictl page list`, reading
/// `index.md`/`log.md`, pulling a sample page — before doing any real work. The
/// app ALREADY knows all of that (it's what the sidebar renders). Handing the
/// agent the current state up front lets it skip rediscovery and go straight to
/// the task.
///
/// **The static/dynamic split (do NOT duplicate).** STATIC structure & conventions
/// — the layout map, page-shape conventions, the `wikictl` reference, and the
/// Ingest/Query/Lint workflows — live in the maintainer schema
/// (`SystemPrompt.defaultBody`, delivered every run via `--append-system-prompt`),
/// the single user-evolvable source of truth for HOW the wiki is shaped. This
/// snapshot carries only DYNAMIC state — what is actually in THIS wiki right now —
/// so it can never drift from the schema (it's derived from the DB at click time).
///
/// PURE value type: it carries the gathered facts and knows how to `render()`
/// itself into the prompt's `CURRENT WIKI STATE` block. Gathering it from the
/// store lives in the app/model layer (`WikiStoreModel.currentStateSnapshot()`);
/// keeping the rendering here keeps it unit-testable without a live store.
public struct WikiStateSnapshot: Equatable, Sendable {
  /// Existing page titles, most-recently-updated first. Capped to
  /// `maxListedTitles` for large wikis (see `truncatedPageCount`).
  public let pageTitles: [String]
  /// How many titles were dropped from `pageTitles` by the cap, so the rendered
  /// block can tell the agent the full set is larger (and how to fetch it).
  public let truncatedPageCount: Int
  /// The current `index.md` body (the curated catalog the agent rewrites on
  /// ingest). Included whole — it's small.
  public let indexBody: String
  /// The most recent log entries, oldest-of-the-tail first (chronological), each
  /// already rendered as its grep-able `## [date] kind | title` line (plus note),
  /// matching exactly what `log.md`'s `tail` would show.
  public let recentLog: [String]
  /// The bookmark tree (folders + page/source/chat refs), flat but ordered
  /// parents-before-children, siblings by position. Included so the agent can
  /// see how the user has organized bookmarks and mirror that structure (#239).
  public let bookmarkNodes: [BookmarkNode]

  /// Cap on listed titles for large wikis: list the most-recently-updated ~150
  /// and note the remainder, so a 10k-page wiki doesn't blow up the prompt.
  public static let maxListedTitles = 150

  /// How many log entries to include in the tail (small; included whole).
  public static let maxLogEntries = 8

  public init(
    pageTitles: [String],
    truncatedPageCount: Int,
    indexBody: String,
    recentLog: [String],
    bookmarkNodes: [BookmarkNode] = []
  ) {
    self.pageTitles = pageTitles
    self.truncatedPageCount = truncatedPageCount
    self.indexBody = indexBody
    self.recentLog = recentLog
    self.bookmarkNodes = bookmarkNodes
  }

  /// Build a snapshot from raw state, applying the large-wiki cap. `allTitles`
  /// must already be most-recently-updated first (as `store.listPages()` returns).
  /// `logLines` must already be the rendered tail, oldest-first.
  ///
  /// Kept pure (no store access) so it's testable: the app gathers the raw lists
  /// at click time and hands them in.
  public static func make(
    allTitles: [String],
    indexBody: String,
    logLines: [String],
    bookmarkNodes: [BookmarkNode] = []
  ) -> WikiStateSnapshot {
    let listed = Array(allTitles.prefix(maxListedTitles))
    let dropped = max(0, allTitles.count - listed.count)
    return WikiStateSnapshot(
      pageTitles: listed,
      truncatedPageCount: dropped,
      indexBody: indexBody,
      recentLog: logLines,
      bookmarkNodes: bookmarkNodes
    )
  }

  /// Render the standalone `WIKI_STATE.md` document the app STAGES into the per-run
  /// scratch dir (read from SQLite, not the laggy mount). The operation prompt names
  /// this file's absolute path and tells the agent to read it instead of running
  /// `wikictl page list` / re-reading `index.md`/`log.md` — so the agent skips
  /// orientation turns (problem #2). It carries the cross-link vocabulary (titles),
  /// the current `index.md` body, and the recent log tail.
  public func renderStateFile() -> String {
    var lines: [String] = []
    lines.append("# WIKI_STATE")
    lines.append("")
    lines.append(
      "Live snapshot of this wiki, authoritative as of run start. This is staged for "
        + "you so you do NOT need to run `wikictl page list` or re-read "
        + "`index.md`/`log.md` to learn the structure.")

    // Existing pages.
    lines.append("")
    lines.append("## Existing pages")
    if pageTitles.isEmpty {
      lines.append("None yet — this is a fresh wiki.")
    } else {
      lines.append(
        "Cross-link to these with [[Title]]; update rather than duplicate.")
      lines.append("")
      lines.append(pageTitles.map { "- \($0)" }.joined(separator: "\n"))
      if truncatedPageCount > 0 {
        lines.append("")
        lines.append(
          "(…and \(truncatedPageCount) more — run `wikictl page list` only if you need the full set.)")
      }
    }

    // index.md body.
    lines.append("")
    lines.append("## index.md (current body — rewrite wholesale on ingest)")
    lines.append("")
    lines.append(indexBody)

    // Recent log tail.
    lines.append("")
    lines.append("## Recent log (most recent last)")
    if recentLog.isEmpty {
      lines.append("Empty.")
    } else {
      lines.append("")
      lines.append(recentLog.joined(separator: "\n"))
    }

    // Bookmark tree (#239: let the agent see the user's bookmark organization).
    lines.append("")
    lines.append("## Bookmarks")
    if bookmarkNodes.isEmpty {
      lines.append("No bookmarks yet.")
    } else {
      lines.append(
        "The user's bookmark organization. Use `wikictl bookmark` subcommands to manage these.")
      lines.append("")
      lines.append(Self.renderBookmarkTree(bookmarkNodes))
    }

    return lines.joined(separator: "\n") + "\n"
  }

  /// Renders a flat `[BookmarkNode]` list (parents-before-children, siblings by
  /// position) as an indented markdown tree. Folders show their label; refs
  /// show their target id. The indentation level reflects nesting depth.
  static func renderBookmarkTree(_ nodes: [BookmarkNode]) -> String {
    // Build parent→children map for tree traversal.
    var childrenMap: [String?: [BookmarkNode]] = [:]
    for node in nodes {
      childrenMap[node.parentID, default: []].append(node)
    }
    // Sort each group by position.
    for key in childrenMap.keys {
      childrenMap[key]?.sort { $0.position < $1.position }
    }

    var lines: [String] = []
    func renderChildren(of parentID: String?, depth: Int) {
      let children = childrenMap[parentID] ?? []
      for child in children {
        let indent = String(repeating: "  ", count: depth)
        let icon: String
        let label: String
        switch child.kind {
        case .folder:
          icon = "📁"
          label = child.label ?? "(unnamed folder)"
        case .pageRef:
          icon = "📄"
          label = "page:\(child.targetID?.rawValue ?? "?")"
        case .sourceRef:
          icon = "📎"
          label = "source:\(child.targetID?.rawValue ?? "?")"
        case .chatRef:
          icon = "💬"
          label = "chat:\(child.targetID?.rawValue ?? "?")"
        }
        lines.append("\(indent)- \(icon) \(label)")
        if child.kind == .folder {
          renderChildren(of: child.id, depth: depth + 1)
        }
      }
    }
    renderChildren(of: nil, depth: 0)
    return lines.joined(separator: "\n")
  }
}

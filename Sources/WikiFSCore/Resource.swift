import Foundation

/// The leaf concept shared by every exposure surface of a wiki's content: the
/// File Provider projection, the resource-change event bus, and (future) MCP
/// (#124) / REST. A `Resource` is a thing with **identity + name + content +
/// version** that can be listed, read, and change-detected.
///
/// Tree *shape* (flat by-id/by-name vs nested folders) is a projection-
/// descriptor concern (Phase B+), NOT part of this protocol — so a flat kind
/// (`page`, `source`) and a nested kind (`bookmark`) can both conform.
///
/// Conformance is added incrementally: this file (Phase A) defines the
/// protocol, the `ResourceKind` vocabulary, and the `changeToken` contributor
/// registry; Phase B conforms `page`/`source` and adds the projection
/// descriptors; Phase D conforms `bookmark`. There are no conformers yet — the
/// protocol is declared now so the vocabulary it carries (`ResourceKind`) has a
/// single home that both the bus and the contributor registry reference.
public protocol Resource: Sendable {
    /// Stable identity (a ULID at rest).
    var id: String { get }
    /// Display name.
    var name: String { get }
    /// Which resource kind this is.
    var kind: ResourceKind { get }
}

/// The vocabulary of resource kinds — the single declaration point a new kind
/// adds. Shared by the event bus (the `kind` on a `ResourceChangeEvent`), the
/// `changeToken` contributor registry, and (Phase B+) the projection descriptor
/// registry. Extensible: `chat` (#119) and others are added as cases here.
///
/// Re-homed here from `WikiEventBus.swift` in slice 2b so the kind vocabulary
/// lives next to the `Resource` abstraction that owns it (the bus is one
/// *consumer* of kinds, not their home).
public enum ResourceKind: String, Sendable, CaseIterable {
    case page, source, systemPrompt, wikiIndex, log, bookmark, chat

    /// The SF Symbol name used for this resource kind across every UI surface:
    /// sidebar sections, detail-view headers, the omnibox icon, bookmark row
    /// icons, source list rows, and the picker sheet. Centralized here so a
    /// kind's icon can't drift between surfaces.
    public var systemImageName: String {
        switch self {
        case .page:        "doc.text"
        case .source:      "tray.full"
        case .bookmark:    "bookmark"
        case .chat:        "bubble.left.and.bubble.right"
        case .systemPrompt: "doc.text"
        case .wikiIndex:   "book.closed"
        case .log:         "clock.arrow.circlepath"
        }
    }
}

/// One fold's structured contribution to the whole-wiki change token.
///
/// Each case carries the named values for one contributor's fold. The cases are
/// the authoritative vocabulary of what the token tracks — adding a new tracked
/// thing means adding a case here (and a contributor returning it). Joining the
/// folds into a ``ChangeToken`` preserves the registry order.
public enum ChangeTokenFold: Sendable {
    case pages(count: Int64, versionSum: Int64)
    case sourceTable(count: Int64, versionSum: Int64)
    case systemPrompt(version: Int64)
    case log(rowCount: Int64)
    case wikiIndex(version: Int64)
    case sourceMarkdownVersions(count: Int64)
    case sourceGraph(versionCount: Int64, refsGenerationSum: Int64, activitiesCount: Int64)
    case bookmarks(count: Int64)
    case chat(count: Int64, messageCount: Int64)
}

/// A structured view over the whole-wiki change token — the File Provider sync
/// anchor and durable, per-wiki ground truth (`plans/architecture-roadmap.md`
/// §5; do NOT merge it with the bus's ephemeral `seq`).
///
/// Each property is a named fold, assembled from per-kind
/// ``ChangeTokenContributor``s in registry order. Tests assert against named
/// fields instead of positional string literals so adding a new fold does not
/// break ~20 hardcoded assertions. The colon-joined form is still available via
/// ``rawString`` for the File Provider, which uses the token as an opaque sync
/// anchor.
public struct ChangeToken: Sendable, Equatable {
    /// The pages fold: `COUNT(pages)` and `SUM(version)`.
    public struct Pages: Sendable, Equatable {
        public var count: Int64 = 0
        public var versionSum: Int64 = 0
    }

    /// The source-table fold: `COUNT(sources)` and `SUM(version)`.
    public struct SourceTable: Sendable, Equatable {
        public var count: Int64 = 0
        public var versionSum: Int64 = 0
    }

    /// The graph-model source folds: `source_versions` count,
    /// `COALESCE(SUM(generation), 0)` over `refs`, and `activities` count.
    public struct SourceGraph: Sendable, Equatable {
        public var versionCount: Int64 = 0
        public var refsGenerationSum: Int64 = 0
        public var activitiesCount: Int64 = 0
    }

    /// The chat fold: `COUNT(chats)` and `COUNT(chat_messages)`.
    public struct Chat: Sendable, Equatable {
        public var count: Int64 = 0
        public var messageCount: Int64 = 0
    }

    public var pages = Pages()
    public var sourceTable = SourceTable()
    public var systemPrompt: Int64 = 0
    public var log: Int64 = 0
    public var wikiIndex: Int64 = 0
    public var sourceMarkdownVersions: Int64 = 0
    public var sourceGraph = SourceGraph()
    public var bookmarks: Int64 = 0
    public var chat = Chat()

    /// Colon-joined form reproducing the historical positional token, for the
    /// File Provider sync anchor. Append-only (never reorder fields).
    public var rawString: String {
        "\(pages.count):\(pages.versionSum):"
        + "\(sourceTable.count):\(sourceTable.versionSum):"
        + "\(systemPrompt):\(log):\(wikiIndex):\(sourceMarkdownVersions):"
        + "\(sourceGraph.versionCount):\(sourceGraph.refsGenerationSum):\(sourceGraph.activitiesCount):"
        + "\(bookmarks):\(chat.count):\(chat.messageCount)"
    }

    /// Applies one fold's values into the matching named field.
    mutating func apply(_ fold: ChangeTokenFold) {
        switch fold {
        case let .pages(count, versionSum):
            pages = Pages(count: count, versionSum: versionSum)
        case let .sourceTable(count, versionSum):
            sourceTable = SourceTable(count: count, versionSum: versionSum)
        case let .systemPrompt(version):
            systemPrompt = version
        case let .log(rowCount):
            log = rowCount
        case let .wikiIndex(version):
            wikiIndex = version
        case let .sourceMarkdownVersions(count):
            sourceMarkdownVersions = count
        case let .sourceGraph(versionCount, refsGenerationSum, activitiesCount):
            sourceGraph = SourceGraph(versionCount: versionCount,
                                      refsGenerationSum: refsGenerationSum,
                                      activitiesCount: activitiesCount)
        case let .bookmarks(count):
            bookmarks = count
        case let .chat(count, messageCount):
            chat = Chat(count: count, messageCount: messageCount)
        }
    }
}

/// Declares one resource kind's contribution to the whole-wiki
/// `SQLiteWikiStore.changeToken()`.
///
/// The token stays ONE whole-database value (``ChangeToken``) — it is the File
/// Provider sync anchor and the durable, per-wiki ground truth
/// (`plans/architecture-roadmap.md` §5; do NOT merge it with the bus's ephemeral
/// `seq`). Slice 2b genericizes only its *construction*: instead of one
/// monolithic method, a registry of per-kind contributors each produce a
/// ``ChangeTokenFold``, joined in registration order. **Adding a kind =
/// appending a contributor (and a fold), not editing a positional literal.**
///
/// Each contributor runs under the store's recursive lock (called from inside
/// `changeToken()`) and reads committed state via the store's read seam. It
/// must return values only — never a statement handle or column pointer
/// (`docs/skills/sqlite-concurrency/SKILL.md`).
public protocol ChangeTokenContributor: Sendable {
    /// The kind whose folds this contributor owns. A kind MAY have more than
    /// one contributor (the historical token interleaves the system-prompt/log/
    /// index folds between the source-table fold and the graph-model source
    /// folds); the registry's order, not this label, defines the token layout.
    var kind: ResourceKind { get }
    /// One structured fold for this kind. Computed under the store's lock from
    /// a read connection. The fold's case carries the named values;
    /// ``ChangeToken.apply(_:)`` routes them into the matching field.
    func fold(in store: SQLiteWikiStore) throws -> ChangeTokenFold
}

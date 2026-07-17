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
    case page, source, systemPrompt, wikiIndex, log, bookmark, chat, connection

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
        case .connection:  "cable.connector"
        }
    }
}

/// Declares one resource kind's contribution to the whole-wiki
/// `SQLiteWikiStore.changeToken()`.
///
/// The token stays ONE whole-database string — it is the File Provider sync
/// anchor and the durable, per-wiki ground truth (`plans/architecture-roadmap.md`
/// §5; do NOT merge it with the bus's ephemeral `seq`). Slice 2b genericizes
/// only its *construction*: instead of one monolithic method, a registry of
/// per-kind contributors each produce a colon-joined fold fragment, joined in
/// registration order. **Adding a kind = appending a contributor (and a fold),
/// not editing an 11-field literal.**
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
    /// One colon-joined fold fragment for this kind. Computed under the store's
    /// lock from a read connection. Slice 2b keeps this byte-identical to the
    /// pre-2b 11-field token; later phases may append (never reorder) fields.
    func fragment(in store: SQLiteWikiStore) throws -> String
}

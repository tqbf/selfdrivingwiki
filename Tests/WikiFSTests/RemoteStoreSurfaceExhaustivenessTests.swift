#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
@testable import WikiCtlCore

// Phase 2 item 2f (plans/daemon-only-access.md): the source-parsed
// exhaustiveness contract for the RemoteWikiStore surface. Swift cannot
// enumerate protocol requirements at runtime, so this test PARSES the
// declarations (the `tmp/gen_pending_surface.py` parser approach, ported
// here so the check survives without the gitignored scratch):
//
// 1. The `public protocol WikiStore` block (Sources/WikiFSCore/Store/
//    WikiStore.swift) — every requirement NAME (overloads collapse to one
//    name; the parser that generated the surface used the same rule).
// 2. `RemoteWikiStore`'s static ledgers (imported directly): `wiredOperations`
//    (RPC ops served over the wire), `removedOperations` (deliberately
//    unserved), plus the three client-metadata properties.
// 3. `DaemonStoreOperation`'s case list (Sources/WikiDaemonContract/
//    DaemonStoreWire.swift), source-parsed AND cross-checked against the
//    compiler-enumerable `allCases`.
// 4. `GRDBWikiStore`'s public funcs (Sources/WikiFSCore/Store/
//    GRDBWikiStore.swift) — the concrete store the daemon executor
//    dispatches against.
//
// The triangle closes: every wired operation is a protocol requirement,
// a `DaemonStoreOperation` case, AND a GRDB public func (so the executor
// never dispatches a protocol-extension default); every removed requirement
// is a protocol requirement and NO operation case; every protocol
// requirement is classified into exactly one of the three buckets.
//
// tmp/store-ops-manifest.md is gitignored scratch, so the manifest's class
// counts are PINNED here as named constants: 151 wired (small 37 / list 25
// / blob 39 / event-producer 50), 15 removed, 3 client properties —
// 169 unique requirement names. Drift in any direction fails.
@Suite
struct RemoteStoreSurfaceExhaustivenessTests {

    // MARK: - Pinned class counts (tmp/store-ops-manifest.md)

    /// Manifest RPC operations wired end to end: small 37 + list 25 +
    /// blob 39 + event-producer 50.
    private static let pinnedWiredCount = 151
    /// `WikiStore` requirements deliberately absent from the remote surface
    /// (each rejects typed as `.unsupportedRemote`).
    private static let pinnedRemovedCount = 15
    /// Client-metadata properties (never RPC): eventBus +
    /// registeredExtractionInputs + registeredRendererSourceTypes.
    private static let pinnedClientPropertyCount = 3
    /// Unique protocol requirement names = 151 + 15 + 3.
    private static let pinnedProtocolRequirementCount =
        pinnedWiredCount + pinnedRemovedCount + pinnedClientPropertyCount
    /// `DaemonStoreOperation` cases: the 151 manifest operations + 8
    /// infrastructure/events operations (payloadBegin, payloadChunk,
    /// payloadCommit, payloadRead, resolveOutcome, sessionBootstrap,
    /// sinkHandshake, upgradeSearchIndex — the P5.2 daemon-scoped events
    /// member beside `sinkHandshake`).
    private static let pinnedOperationCaseCount = pinnedWiredCount + 8

    private static let clientProperties: Set<String> = [
        "eventBus", "registeredExtractionInputs",
        "registeredRendererSourceTypes",
    ]

    // MARK: - Source resolution

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // <name>.swift
            .deletingLastPathComponent()   // WikiFSTests/
            .deletingLastPathComponent()   // Tests/ → repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            Issue.record("missing source file: \(relativePath) — \(error)")
            throw error
        }
    }

    // MARK: - Parsing (the gen_pending_surface.py approach, in Swift)

    /// Brace-matched block from `anchor` to its closing brace, skipping
    /// line and block comments (doc comments in these files carry braces).
    private func braceMatchedBlock(
        _ text: String, anchor: String, source: String
    ) throws -> Substring {
        guard let range = text.range(of: anchor) else {
            Issue.record("\(source): anchor not found: \(anchor)")
            throw CancellationError()
        }
        var depth = 0
        var inLineComment = false
        var inBlockComment = false
        var index = range.lowerBound
        while index < text.endIndex {
            let character = text[index]
            if inLineComment {
                if character == "\n" { inLineComment = false }
            } else if inBlockComment {
                if character == "*" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "/" {
                        inBlockComment = false
                        index = next
                    }
                }
            } else if character == "/" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    if text[next] == "/" {
                        inLineComment = true
                        index = next
                    } else if text[next] == "*" {
                        inBlockComment = true
                        index = next
                    }
                }
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return text[range.lowerBound..<index]
                }
            }
            index = text.index(after: index)
        }
        Issue.record("\(source): block from \(anchor) never closed")
        throw CancellationError()
    }

    private struct Requirement {
        let name: String
        let kind: String  // "func" | "var"
    }

    /// Every requirement declaration in the block, joined across wrapped
    /// lines, reduced to (name, kind). Overloads share a name.
    private func requirements(in block: Substring) -> [Requirement] {
        let lines = block.split(separator: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") {
                return ""
            }
            return trimmed
        }

        var declarations: [String] = []
        var buffer: String?
        for line in lines where !line.isEmpty {
            if buffer == nil {
                // Requirements carry no access modifiers; an attribute on
                // its own line (@discardableResult) is skipped and the
                // func/var line starts the declaration.
                if !line.hasPrefix("func ") && !line.hasPrefix("var ") {
                    continue
                }
                buffer = line
            } else {
                buffer! += " " + line
            }
            let parens = buffer!.filter { $0 == "(" }.count
                - buffer!.filter { $0 == ")" }.count
            var ended = false
            if parens == 0 {
                if buffer!.hasPrefix("var "),
                   buffer!.contains("{ get set }")
                    || buffer!.contains("{ get }") {
                    ended = true
                } else if buffer!.hasPrefix("func "),
                          !buffer!.hasSuffix(","),
                          !buffer!.hasSuffix("(") {
                    ended = true
                }
            }
            if ended {
                declarations.append(buffer!)
                buffer = nil
            }
        }
        if let unterminated = buffer {
            Issue.record("unterminated protocol requirement: \(unterminated)")
        }

        var parsed: [Requirement] = []
        for declaration in declarations {
            var body = declaration
            if body.hasPrefix("@discardableResult") {
                body = String(body.dropFirst("@discardableResult".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            let parts = body.split(
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "(" })
            guard parts.count >= 2,
                  let keyword = parts.first,
                  keyword == "func" || keyword == "var" else {
                Issue.record("unparsed protocol requirement: \(declaration)")
                continue
            }
            // The name stops at the identifier boundary: a var's tokens
            // include the type-annotation colon ("eventBus:").
            let rawName = parts[1]
            let name = String(rawName.prefix(while: {
                $0.isLetter || $0.isNumber || $0 == "_"
            }))
            guard !name.isEmpty else {
                Issue.record("unparsed protocol requirement: \(declaration)")
                continue
            }
            parsed.append(
                Requirement(name: name, kind: String(keyword)))
        }
        return parsed
    }

    /// `case <name>` lines inside a brace-matched enum block.
    private func enumCaseNames(in block: Substring) -> Set<String> {
        var names: Set<String> = []
        for line in block.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            let token = String(trimmed.dropFirst("case ".count))
                .trimmingCharacters(in: .whitespaces)
            let name = token.prefix(while: {
                $0.isLetter || $0.isNumber || $0 == "_"
            })
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    /// `public func <name>` occurrences, one identifier per line.
    private func publicFuncNames(in text: String) -> Set<String> {
        var names: Set<String> = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public func ") else { continue }
            let rest = String(trimmed.dropFirst("public func ".count))
            let name = rest.prefix(while: {
                $0.isLetter || $0.isNumber || $0 == "_"
            })
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    // MARK: - The contract

    @Test func remoteStoreSurfaceIsAnExhaustiveClassifiedPartition()
        throws {
        let protocolText = try readSource(
            "Sources/WikiFSCore/Store/WikiStore.swift")
        let block = try braceMatchedBlock(
            protocolText,
            anchor: "public protocol WikiStore: AnyObject, Sendable {",
            source: "WikiStore.swift")
        let requirements = requirements(in: block)

        // Unique requirement names (overloads collapse — the same rule the
        // surface generator used).
        let names = Set(requirements.map(\.name))
        #expect(
            names.count == Self.pinnedProtocolRequirementCount,
            "the WikiStore protocol has \(names.count) unique requirement names; expected \(Self.pinnedProtocolRequirementCount) (151 wired + 15 removed + 3 client properties) — update the classification, not the pin")

        // The three client properties are EXACTLY the protocol's var
        // requirements — a new settable protocol property is client
        // metadata by construction and must join the set explicitly.
        let varRequirements = Set(
            requirements.filter { $0.kind == "var" }.map(\.name))
        #expect(
            varRequirements == Self.clientProperties,
            "the protocol's var requirements \(varRequirements.sorted()) must be exactly the client-metadata set \(Self.clientProperties.sorted())")

        // The ledgers under test (the LIVE declarations).
        let wired = RemoteWikiStore.wiredOperations
        let removed = RemoteWikiStore.removedOperations

        #expect(
            wired.count == Self.pinnedWiredCount,
            "wiredOperations holds \(wired.count); the manifest pins \(Self.pinnedWiredCount) (small 37 / list 25 / blob 39 / event-producer 50) — see tmp/store-ops-manifest.md")
        #expect(
            removed.count == Self.pinnedRemovedCount,
            "removedOperations holds \(removed.count); the manifest pins \(Self.pinnedRemovedCount)")

        // Partition, both directions: every requirement classified, every
        // classification a real requirement.
        let classified = wired.union(removed).union(Self.clientProperties)
        #expect(
            classified == names,
            "unclassified or stale classifications — missing: \(names.subtracting(classified).sorted()) stale: \(classified.subtracting(names).sorted())")
        #expect(
            wired.isDisjoint(with: removed),
            "an operation cannot be both wired and removed")
        #expect(
            wired.isDisjoint(with: Self.clientProperties),
            "a client property is never an RPC op")
        #expect(
            removed.isDisjoint(with: Self.clientProperties),
            "a client property is never removed — it always exists locally")

        // The triangle: every wired operation is a DaemonStoreOperation
        // case (source-parsed AND compiler-enumerated) AND a GRDBWikiStore
        // public func (the executor dispatches real implementations, never
        // protocol-extension defaults).
        let wireText = try readSource(
            "Sources/WikiDaemonContract/DaemonStoreWire.swift")
        let enumBlock = try braceMatchedBlock(
            wireText,
            anchor: "public enum DaemonStoreOperation: String, Codable, Sendable, CaseIterable {",
            source: "DaemonStoreWire.swift")
        let parsedCases = enumCaseNames(in: enumBlock)
        #expect(
            parsedCases.count == Self.pinnedOperationCaseCount,
            "DaemonStoreOperation parses to \(parsedCases.count) cases; pinned \(Self.pinnedOperationCaseCount) (151 manifest + 7 infrastructure/events)")
        #expect(
            parsedCases.count == DaemonStoreOperation.allCases.count,
            "the source-parsed case list and the compiler's allCases disagree (\(parsedCases.count) vs \(DaemonStoreOperation.allCases.count))")

        let operationRawValues = Set(
            DaemonStoreOperation.allCases.map(\.rawValue))
        #expect(
            parsedCases == operationRawValues,
            "a parsed case name is not a live rawValue (or vice versa)")

        #expect(
            wired.isSubset(of: operationRawValues),
            "wired operations without a wire case: \(wired.subtracting(operationRawValues).sorted())")
        #expect(
            removed.isDisjoint(with: operationRawValues),
            "removed requirements must have NO operation case: \(removed.intersection(operationRawValues).sorted())")

        let grdbText = try readSource(
            "Sources/WikiFSCore/Store/GRDBWikiStore.swift")
        let grdbFuncs = publicFuncNames(in: grdbText)
        #expect(
            wired.isSubset(of: grdbFuncs),
            "wired operations without a GRDB implementation (the executor would dispatch a protocol-extension default): \(wired.subtracting(grdbFuncs).sorted())")
    }
}
#endif

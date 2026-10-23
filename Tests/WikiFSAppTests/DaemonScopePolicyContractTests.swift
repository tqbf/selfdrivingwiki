#if os(macOS)
import Foundation
import Testing
@testable import WikiDaemonContract
@testable import wikid

/// THE exhaustive operation-classification contract
/// (plans/agent-sandbox-scoping.md §6: "Do not grant all operations in a
/// family because one operation is safe. Add contract tests that classify
/// every family/operation pair.").
///
/// The test PARSES the operation constants out of the contract source (the
/// same source-parsing discipline as `StoreEmissionExhaustivenessTests`) and
/// requires `DaemonScopedOperationPolicy.table` to carry an explicit row for
/// EVERY family/operation pair that exists — so adding an operation without
/// making a policy decision fails this gate instead of silently inheriting
/// the deny-by-default (which would only show up as a mysterious CLI
/// failure later).
@Suite("Daemon scope policy contract", .timeLimit(.minutes(1)))
struct DaemonScopePolicyContractTests {

    // MARK: Source parsing

    private struct ParsedOperation {
        let family: DaemonDomainFamily
        let operation: String
    }

    /// Every `public static let NAME = "value"` under
    /// `DaemonDomainOperation`'s nested enums, mapped to its family. The
    /// nested enum name maps to the family raw value by lowercasing the
    /// first letter (`Hello` → `hello`), which holds for every family.
    private func parseOperations() throws -> [ParsedOperation] {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("Sources/WikiDaemonContract/DaemonDomainWire.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let block = try Self.declaration(
            named: "public enum DaemonDomainOperation", in: source)
        var parsed: [ParsedOperation] = []
        // Skip the OUTER enum's own header before scanning for nested enums,
        // or "DaemonDomainOperation" would self-match as a family.
        var cursor = block.startIndex
        if let outerHeader = block.range(of: "public enum ", range: cursor..<block.endIndex) {
            let nameStart = outerHeader.upperBound
            if let nameEnd = block[nameStart...].firstIndex(where: { $0 == " " || $0 == "{" }) {
                cursor = nameEnd
            }
        }
        while let range = block.range(of: "public enum ", range: cursor..<block.endIndex) {
            // The nested enum's name: the identifier right after the marker.
            let nameStart = range.upperBound
            let nameEnd = block[nameStart...].firstIndex(where: { $0 == " " || $0 == "{" })
                ?? block.endIndex
            let enumName = String(block[nameStart..<nameEnd])
            let body = try Self.declaration(named: "public enum \(enumName)", in: block)
            for match in body.matches(of: /public static let \w+ = "([^"]+)"/) {
                guard let family = DaemonDomainFamily(
                    rawValue: lowerFirst(enumName))
                else {
                    Issue.record(
                        "nested operation enum \(enumName) has no DaemonDomainFamily case")
                    continue
                }
                parsed.append(
                    ParsedOperation(
                        family: family,
                        operation: String(match.1)))
            }
            cursor = nameEnd
        }
        return parsed
    }

    private func lowerFirst(_ name: String) -> String {
        name.prefix(1).lowercased() + name.dropFirst()
    }

    /// The balanced-brace block starting at `named` (which must appear at a
    /// line start), matching braces OUTSIDE string literals and comments.
    private static func declaration(named: String, in source: String) throws -> String {
        guard let start = source.range(of: named) else {
            throw DeclarationNotFound(name: named)
        }
        guard let openBrace = source[start.upperBound...].firstIndex(of: "{") else {
            throw DeclarationNotFound(name: named)
        }
        var depth = 0
        var inString = false
        var iterator = openBrace
        while iterator < source.endIndex {
            let character = source[iterator]
            switch character {
            case "\"" where !inString:
                inString = true
            case "\"" where inString:
                inString = false
            case "{" where !inString:
                depth += 1
            case "}" where !inString:
                depth -= 1
                if depth == 0 {
                    return String(source[start.lowerBound...iterator])
                }
            default:
                break
            }
            iterator = source.index(after: iterator)
        }
        throw DeclarationNotFound(name: "\(named) (unbalanced)")
    }

    private struct DeclarationNotFound: Error, CustomStringConvertible {
        let name: String
        var description: String { "declaration not found: \(name)" }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: Exhaustiveness

    @Test("every family/operation pair in the contract has an explicit policy row")
    func everyContractOperationPairIsClassified() throws {
        let parsed = try parseOperations()
        #expect(
            parsed.count >= 60,
            "the parser must find the full operation catalog (found \(parsed.count)); if the count drops, the DaemonDomainOperation source shape changed")
        for operation in parsed {
            let row = DaemonScopedOperationPolicy.table[operation.family]?[operation.operation]
            #expect(
                row != nil,
                "unclassified scoped-operation pair \(operation.family.rawValue)/\(operation.operation): add an explicit allow, protocolOnly, or deny row to DaemonScopedOperationPolicy.table (runtime absence denies fail-closed, but the DECISION must be made here)")
        }
    }

    @Test("every family carries at least one classified operation")
    func everyFamilyHasATableEntry() {
        for family in DaemonDomainFamily.allCases {
            let entry = DaemonScopedOperationPolicy.table[family]
            #expect(entry != nil, "family \(family.rawValue) has no policy table entry")
            #expect(
                (entry?.isEmpty ?? true) == false,
                "family \(family.rawValue) has an EMPTY policy table entry")
        }
    }

    @Test("unknown operations fail closed")
    func unknownOperationsDeny() {
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .page, operation: "definitelyNotAnOperation") == .deny)
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .wiki, operation: "teleportWiki") == .deny)
    }

    // MARK: The approved policy anchors (plan §6 initial policy + §13 decisions)

    @Test("registry mutation and global enumeration are denied")
    func registryMutationAndEnumerationDenied() {
        for operation in [
            DaemonDomainOperation.Wiki.listWikis,
            DaemonDomainOperation.Wiki.createWiki,
            DaemonDomainOperation.Wiki.deleteWiki,
            DaemonDomainOperation.Wiki.renameWiki,
        ] {
            #expect(
                DaemonScopedOperationPolicy.decision(family: .wiki, operation: operation)
                    == .deny,
                "wiki/\(operation) must be denied for scoped runs")
        }
        // Scoped RESOLUTION is the one registry read that answers.
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .wiki, operation: DaemonDomainOperation.Wiki.resolveWiki)
                == .allow(.wikiRead))
    }

    @Test("global queue controls and snapshots are denied")
    func globalQueueControlsDenied() {
        for operation in [
            DaemonDomainOperation.Queue.queueSnapshot,
            DaemonDomainOperation.Queue.pauseQueue,
            DaemonDomainOperation.Queue.resumeQueue,
            DaemonDomainOperation.Queue.haltQueue,
        ] {
            #expect(
                DaemonScopedOperationPolicy.decision(family: .queue, operation: operation)
                    == .deny,
                "queue/\(operation) must be denied for scoped runs")
        }
    }

    @Test("admin maintenance is denied wholesale (§13.4)")
    func adminDenied() {
        for operation in [
            DaemonDomainOperation.Admin.vacuumBlobs,
            DaemonDomainOperation.Admin.vacuumActivities,
            DaemonDomainOperation.Admin.vacuumPageVersions,
            DaemonDomainOperation.Admin.vacuumAll,
            DaemonDomainOperation.Admin.repairMIME,
        ] {
            #expect(
                DaemonScopedOperationPolicy.decision(family: .admin, operation: operation)
                    == .deny)
        }
    }

    @Test("scoped source export and refresh are denied (§13.3, §13.4)")
    func scopedExportAndRefreshDenied() {
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .source, operation: DaemonDomainOperation.Source.export) == .deny)
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .source, operation: DaemonDomainOperation.Source.refresh) == .deny)
        // The scoped READ alternative stays available: source cat is a read.
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .source, operation: DaemonDomainOperation.Source.cat)
                == .allow(.wikiRead))
    }

    @Test("the hello handshake is protocol-only, and the classes partition the rest")
    func protocolOnlyAndClassAnchors() {
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .hello, operation: DaemonDomainOperation.Hello.capabilities)
                == .protocolOnly)
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .page, operation: DaemonDomainOperation.Page.list)
                == .allow(.wikiRead))
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .page, operation: DaemonDomainOperation.Page.add)
                == .allow(.wikiEdit))
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .queue, operation: DaemonDomainOperation.Queue.enqueueItem)
                == .allow(.wikiAcquire))
        #expect(
            DaemonScopedOperationPolicy.decision(
                family: .extractor, operation: DaemonDomainOperation.Extractor.sync)
                == .allow(.wikiAcquire))
    }
}
#endif

import Foundation
import SQLite3
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiCtlCore

@Suite(.serialized)
struct MIMERepairTests {
    @Test func dryRunDoesNotWrite() throws {
        let fixture = try makeFixture(sourceMIMEIsNull: true, versionMIMEIsNull: true)
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        let report = try store.repairMIME(dryRun: true)

        #expect(report.scannedCount == 1)
        #expect(report.repairableCount == 1)
        #expect(report.updatedCount == 0)
        #expect(report.applied == false)
        #expect(report.items.first?.nullState == .both)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID) == ["NULL|NULL"])
    }

    @Test func applyRepairsBothNullMirrors() throws {
        let fixture = try makeFixture(sourceMIMEIsNull: true, versionMIMEIsNull: true)
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        let report = try store.repairMIME(dryRun: false)

        #expect(report.updatedCount == 1)
        #expect(report.items.first?.newMIMEType == "application/pdf")
        #expect(report.items.first?.updated == true)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID) == ["application/pdf|application/pdf"])
    }

    @Test(arguments: [(true, false, MIMERepairNullState.sourceOnly), (false, true, .activeVersionOnly)])
    func applyRepairsOneSidedNullAndOverwritesOtherMirror(
        sourceMIMEIsNull: Bool,
        versionMIMEIsNull: Bool,
        expectedState: MIMERepairNullState
    ) throws {
        let fixture = try makeFixture(
            sourceMIMEIsNull: sourceMIMEIsNull,
            versionMIMEIsNull: versionMIMEIsNull,
            nonNullMIME: "text/plain")
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        let report = try store.repairMIME(dryRun: false)

        #expect(report.items.first?.nullState == expectedState)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID) == ["application/pdf|application/pdf"])
    }

    @Test func skipsInconclusiveUnknownBinary() throws {
        let fixture = try makeFixture(
            bytes: Data([0x00, 0xFF, 0x00, 0x81]),
            filename: "unknown",
            sourceMIMEIsNull: true,
            versionMIMEIsNull: true)
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        let report = try store.repairMIME(dryRun: false)

        #expect(report.repairableCount == 0)
        #expect(report.updatedCount == 0)
        #expect(report.skippedInconclusiveCount == 1)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID) == ["NULL|NULL"])
    }

    @Test func activeRefWinsAndPreservesInactiveVersionMIME() throws {
        let fixture = try makeFixture(sourceMIMEIsNull: false, versionMIMEIsNull: false)
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        let newer = try store.appendContentVersion(
            sourceID: fixture.sourceID,
            data: Data("new text".utf8),
            detectionHints: ContentTypeDetectionHints(
                declaredMIME: DeclaredMIME("text/plain", origin: .httpResponse)),
            provenance: nil)
        try execute(
            "UPDATE refs SET version_id=\(sql(fixture.activeVersionID.rawValue)) " +
            "WHERE kind='source-content' AND owner_id=\(sql(fixture.sourceID.rawValue));" +
            "UPDATE sources SET mime_type=NULL WHERE id=\(sql(fixture.sourceID.rawValue));" +
            "UPDATE source_versions SET mime_type=NULL WHERE id=\(sql(fixture.activeVersionID.rawValue));",
            at: fixture.url)

        let report = try store.repairMIME(dryRun: false)

        #expect(report.updatedCount == 1)
        #expect(report.items.first?.sourceVersionID == fixture.activeVersionID)
        #expect(try versionMIME(at: fixture.url, versionID: fixture.activeVersionID) == "application/pdf")
        #expect(try versionMIME(at: fixture.url, versionID: newer.id) == "text/plain")
    }

    @Test func applyEmitsOneEventAndNoOpEmitsNone() async throws {
        let fixture = try makeFixture(sourceMIMEIsNull: true, versionMIMEIsNull: true)
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "MIME-REPAIR"))
        store.eventBus = bus
        let recorder = EventRecorder()
        bus.subscribe(nil) { recorder.append($0) }

        _ = try store.repairMIME(dryRun: false)
        let events = await waitForEvents(recorder, expected: 1)
        #expect(events.count == 1)
        #expect(events.first?.kind == .source)
        #expect(events.first?.id == fixture.sourceID.rawValue)
        #expect(events.first?.change == .updated)

        recorder.clear()
        let second = try store.repairMIME(dryRun: false)
        #expect(second.updatedCount == 0)
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(recorder.snapshot.isEmpty)
    }

    @Test func adminCommandParsesAndFormatsTextAndJSON() throws {
        let dry = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "repair-mime"], env: { _ in nil })
        let applyJSON = try ArgumentParser.parse(
            ["--wiki", "W", "admin", "repair-mime", "--apply", "--json"], env: { _ in nil })
        #expect(dry.command == .admin(.repairMIME(dryRun: true, json: false)))
        #expect(applyJSON.command == .admin(.repairMIME(dryRun: false, json: true)))

        let fixture = try makeFixture(sourceMIMEIsNull: true, versionMIMEIsNull: true)
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        let text = try AdminCommand.run(.repairMIME(dryRun: true, json: false), in: store)
        guard case .text(let output) = text.payload else {
            Issue.record("expected text output")
            return
        }
        #expect(text.didCommit == false)
        #expect(output.contains("dry-run; no data changed"))
        #expect(output.contains("both"))
        #expect(output.contains("application/pdf"))

        let json = try AdminCommand.run(.repairMIME(dryRun: true, json: true), in: store)
        guard case .text(let jsonOutput) = json.payload else {
            Issue.record("expected JSON output")
            return
        }
        let decoded = try JSONDecoder().decode(MIMERepairReport.self, from: Data(jsonOutput.utf8))
        #expect(decoded.repairableCount == 1)
        #expect(decoded.items.first?.detection.normalizedMIMEType == "application/pdf")
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []

        func append(_ event: ResourceChangeEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var snapshot: [ResourceChangeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        func clear() {
            lock.lock()
            events.removeAll()
            lock.unlock()
        }
    }

    private struct Fixture {
        let url: URL
        let sourceID: SourceID
        let activeVersionID: SourceVersionID
    }

    private func waitForEvents(
        _ recorder: EventRecorder,
        expected: Int
    ) async -> [ResourceChangeEvent] {
        for _ in 0..<100 {
            if recorder.snapshot.count >= expected { return recorder.snapshot }
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return recorder.snapshot
    }

    private func makeFixture(
        bytes: Data = Data("%PDF-1.7".utf8),
        filename: String = "renamed.txt",
        sourceMIMEIsNull: Bool,
        versionMIMEIsNull: Bool,
        nonNullMIME: String = "application/pdf"
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mime-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WikiFS.sqlite")
        let store = try GRDBWikiStore(databaseURL: url)
        let source = try store.addSource(filename: filename, data: bytes)
        let version = try #require(try store.activeContentVersion(sourceID: source.id))
        let sourceValue = sourceMIMEIsNull ? "NULL" : sql(nonNullMIME)
        let versionValue = versionMIMEIsNull ? "NULL" : sql(nonNullMIME)
        let statement =
            "UPDATE sources SET mime_type = \(sourceValue) WHERE id = \(sql(source.id.rawValue));" +
            "UPDATE source_versions SET mime_type = \(versionValue) WHERE id = \(sql(version.id.rawValue));"
        try execute(statement, at: url)
        return Fixture(url: url, sourceID: source.id, activeVersionID: version.id)
    }

    private func mimeRows(at url: URL, sourceID: SourceID) throws -> [String] {
        try query(
            "SELECT COALESCE(s.mime_type, 'NULL') || '|' || COALESCE(sv.mime_type, 'NULL') " +
            "FROM sources s JOIN refs r ON r.kind='source-content' AND r.owner_id=s.id " +
            "JOIN source_versions sv ON sv.id=r.version_id WHERE s.id=\(sql(sourceID.rawValue));",
            at: url)
    }

    private func versionMIME(at url: URL, versionID: SourceVersionID) throws -> String? {
        try query(
            "SELECT COALESCE(mime_type, 'NULL') FROM source_versions " +
            "WHERE id=\(sql(versionID.rawValue));",
            at: url).first
    }

    private func execute(_ statement: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw WikiStoreError.open("fixture open failed") }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw WikiStoreError.unexpected("fixture write failed")
        }
    }

    private func query(_ statement: String, at url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw WikiStoreError.open("fixture open failed") }
        defer { sqlite3_close(db) }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &prepared, nil) == SQLITE_OK else {
            throw WikiStoreError.unexpected("fixture query prepare failed")
        }
        defer { sqlite3_finalize(prepared) }
        var values: [String] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            if let text = sqlite3_column_text(prepared, 0) { values.append(String(cString: text)) }
        }
        return values
    }

    private func sql(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    // MARK: - Package-alias normalization (revision-6 source types)

    /// The reviewed Mermaid package's validated descriptor: canonical
    /// `text/vnd.mermaid` with the karaoke platform MIME as an alias.
    private func mermaidCatalog() throws -> RegisteredRendererSourceTypes {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            RendererManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("RendererPackages/Mermaid/manifest.json")))
        return RegisteredRendererSourceTypes(descriptors: manifest.descriptors)
    }

    private func installCatalog(
        _ catalog: RegisteredRendererSourceTypes,
        into store: GRDBWikiStore
    ) {
        store.registeredRendererSourceTypes = catalog
    }

    @Test func packageAliasDryRunDoesNotWrite() throws {
        let fixture = try makeFixture(
            bytes: Data("graph TD\n    A --> B\n".utf8),
            filename: "diagram.mmd",
            sourceMIMEIsNull: false,
            versionMIMEIsNull: false,
            nonNullMIME: "application/vnd.chipnuts.karaoke-mmd")
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        installCatalog(try mermaidCatalog(), into: store)

        let report = try store.repairMIME(dryRun: true)

        #expect(report.scannedCount == 1)
        #expect(report.items.first?.status == .packageAliasNormalization)
        #expect(report.items.first?.newMIMEType == "text/vnd.mermaid")
        #expect(report.repairableCount == 1)
        #expect(report.updatedCount == 0)
        #expect(report.applied == false)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID)
            == ["application/vnd.chipnuts.karaoke-mmd|application/vnd.chipnuts.karaoke-mmd"])
    }

    /// H1 regression: package normalization takes precedence over detector
    /// repair for NULL-mirror rows, and a valid alias mirror survives a
    /// NULL sibling. Both mirror shapes must land on the canonical MIME —
    /// never on the detector's generic text/plain, which would strand the
    /// row outside the candidate set forever.
    @Test func packageNormalizationPrecedesDetectorRepairForNullMirrors() throws {
        let catalog = try mermaidCatalog()

        // Both mirrors NULL.
        let bothNull = try makeFixture(
            bytes: Data("graph TD\n    A --> B\n".utf8),
            filename: "fresh.mmd",
            sourceMIMEIsNull: true,
            versionMIMEIsNull: true)
        let store = try GRDBWikiStore(databaseURL: bothNull.url)
        installCatalog(catalog, into: store)
        let report = try store.repairMIME(dryRun: false)
        #expect(report.items.first?.status == .packageAliasNormalization)
        #expect(report.items.first?.newMIMEType == "text/vnd.mermaid")
        #expect(try mimeRows(at: bothNull.url, sourceID: bothNull.sourceID)
            == ["text/vnd.mermaid|text/vnd.mermaid"])

        // Half-null: the karaoke alias on one mirror must survive.
        let halfNull = try makeFixture(
            bytes: Data("sequenceDiagram\n  A->>B: hi\n".utf8),
            filename: "sequence.mmd",
            sourceMIMEIsNull: false,
            versionMIMEIsNull: true,
            nonNullMIME: "application/vnd.chipnuts.karaoke-mmd")
        let secondStore = try GRDBWikiStore(databaseURL: halfNull.url)
        installCatalog(catalog, into: secondStore)
        let secondReport = try secondStore.repairMIME(dryRun: false)
        #expect(secondReport.items.first?.status == .packageAliasNormalization)
        #expect(try mimeRows(at: halfNull.url, sourceID: halfNull.sourceID)
            == ["text/vnd.mermaid|text/vnd.mermaid"])
    }

    @Test func packageAliasApplyUpdatesActiveMirrors() throws {
        let fixture = try makeFixture(
            bytes: Data("graph TD\n    A --> B\n".utf8),
            filename: "diagram.mmd",
            sourceMIMEIsNull: false,
            versionMIMEIsNull: false,
            nonNullMIME: "application/vnd.chipnuts.karaoke-mmd")
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        installCatalog(try mermaidCatalog(), into: store)

        let report = try store.repairMIME(dryRun: false)

        #expect(report.updatedCount == 1)
        #expect(report.items.first?.status == .packageAliasNormalization)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID)
            == ["text/vnd.mermaid|text/vnd.mermaid"])
    }

    @Test func packageAliasRepairEmitsOnceAndIsIdempotent() async throws {
        let fixture = try makeFixture(
            bytes: Data("graph TD\n    A --> B\n".utf8),
            filename: "diagram.mmd",
            sourceMIMEIsNull: false,
            versionMIMEIsNull: false,
            nonNullMIME: "application/vnd.chipnuts.karaoke-mmd")
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        installCatalog(try mermaidCatalog(), into: store)
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "MIME-REPAIR-PKG"))
        store.eventBus = bus
        let recorder = EventRecorder()
        bus.subscribe(nil) { recorder.append($0) }

        let first = try store.repairMIME(dryRun: false)
        #expect(first.updatedCount == 1)
        let events = await waitForEvents(recorder, expected: 1)
        #expect(events.count == 1)
        #expect(events.first?.change == .updated)

        recorder.clear()
        let second = try store.repairMIME(dryRun: false)
        #expect(second.updatedCount == 0)
        #expect(second.items.first?.status == .canonicalNoOp)
        #expect(second.repairableCount == 0)
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(recorder.snapshot.isEmpty)
    }

    @Test func packageAmbiguitySkips() throws {
        // Two descriptors claim the same alias with different canonical
        // values: resolution fails closed and nothing is written.
        func descriptor(registration: String, canonical: String, displayName: String) throws -> RendererDescriptor {
            let canonicalMIME = try RendererMIMEType(validating: canonical)
            let alias = try RendererMIMEType(validating: "application/x-dual")
            let ext = try RendererFileExtension(validating: "dual")
            let asset = RendererAsset(
                path: try .init(validating: "index.html"),
                digest: try RendererSHA256Digest(bytes: Array(repeating: 0, count: RendererSHA256Digest.byteCount)))
            return try RendererDescriptor(
                reference: .init(
                    packageID: try .init(validating: "org.example.\(registration)"),
                    version: try .init(validating: "1.0.0"),
                    registrationID: try .init(validating: registration)),
                displayName: displayName,
                implementation: .webPackage(.init(path: asset.path)),
                matchers: [.normalizedMIME(canonicalMIME), .normalizedMIME(alias), .extensionFallback(ext)],
                sourceType: .init(canonicalMIMEType: canonicalMIME, mimeAliases: [alias], filenameExtensions: [ext]),
                presentations: [.web],
                supportedEmbeddingRoles: [.disclosureRow],
                hasExplicitEmbeddingRoles: true,
                approvedAssets: [asset],
                capabilities: [.inputRead],
                sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
                linkPolicy: .none,
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
                priority: 0)
        }
        let ambiguous = RegisteredRendererSourceTypes(descriptors: [
            try descriptor(registration: "first", canonical: "text/vnd.first", displayName: "First"),
            try descriptor(registration: "second", canonical: "text/vnd.second", displayName: "Second"),
        ])
        let fixture = try makeFixture(
            bytes: Data("dual content".utf8),
            filename: "row.dual",
            sourceMIMEIsNull: false,
            versionMIMEIsNull: false,
            nonNullMIME: "application/x-dual")
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        installCatalog(ambiguous, into: store)

        let report = try store.repairMIME(dryRun: false)

        #expect(report.items.first?.status == .ambiguity)
        #expect(report.updatedCount == 0)
        #expect(report.skippedInconclusiveCount == 1)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID)
            == ["application/x-dual|application/x-dual"])
    }

    @Test func packageAbsenceDoesNotRewrite() throws {
        let fixture = try makeFixture(
            bytes: Data("graph TD\n    A --> B\n".utf8),
            filename: "diagram.mmd",
            sourceMIMEIsNull: false,
            versionMIMEIsNull: false,
            nonNullMIME: "application/vnd.chipnuts.karaoke-mmd")
        let store = try GRDBWikiStore(databaseURL: fixture.url)

        let report = try store.repairMIME(dryRun: false)

        // The karaoke MIME belongs to no declared claim, so the row is not
        // even a candidate.
        #expect(report.scannedCount == 0)
        #expect(report.updatedCount == 0)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID)
            == ["application/vnd.chipnuts.karaoke-mmd|application/vnd.chipnuts.karaoke-mmd"])
    }

    /// A fictional artifact-gated claim: a valid artifact between the 4 KiB
    /// sniff bound and the 64 KiB artifact bound proves repair reads the
    /// independent artifact channel.
    @Test func completeArtifactBetweenSniffAndArtifactLimitsRepairsAlias() throws {
        let catalog = try artifactGatedCatalog()
        let padding = String(repeating: " ", count: RendererMatchingLimits.maximumSniffByteCount)
        let bytes = Data("{\"k\":\"v\",\"elements\":[{}]\(padding)}".utf8)
        #expect(bytes.count > RendererMatchingLimits.maximumSniffByteCount)
        #expect(bytes.count <= ContentArtifactValidationLimits.maximumInputByteCount)
        let fixture = try makeFixture(
            bytes: bytes,
            filename: "sheet.bigjson",
            sourceMIMEIsNull: false,
            versionMIMEIsNull: false,
            nonNullMIME: "application/x-bigjson")
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        installCatalog(catalog, into: store)

        let report = try store.repairMIME(dryRun: false)

        #expect(report.items.first?.status == .packageAliasNormalization)
        #expect(report.updatedCount == 1)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID)
            == ["application/json|application/json"])
    }

    @Test func artifactAboveMaximumIsInconclusive() throws {
        let catalog = try artifactGatedCatalog()
        let bytes = Data(repeating: 0x20, count: ContentArtifactValidationLimits.maximumInputByteCount + 16)
        let fixture = try makeFixture(
            bytes: bytes,
            filename: "sheet.bigjson",
            sourceMIMEIsNull: false,
            versionMIMEIsNull: false,
            nonNullMIME: "application/x-bigjson")
        let store = try GRDBWikiStore(databaseURL: fixture.url)
        installCatalog(catalog, into: store)

        let report = try store.repairMIME(dryRun: false)

        // The artifact channel is truncated past 64 KiB: the required
        // complete-JSON predicate cannot pass, so the row fails closed.
        #expect(report.items.first?.status == .inconclusive)
        #expect(report.updatedCount == 0)
        #expect(report.skippedInconclusiveCount == 1)
        #expect(try mimeRows(at: fixture.url, sourceID: fixture.sourceID)
            == ["application/x-bigjson|application/x-bigjson"])
    }

    private func artifactGatedCatalog() throws -> RegisteredRendererSourceTypes {
        let canonical = try RendererMIMEType(validating: "application/json")
        let alias = try RendererMIMEType(validating: "application/x-bigjson")
        let ext = try RendererFileExtension(validating: "bigjson")
        let constraints = try RendererJSONConstraints(
            properties: ["k": .stringEquals("v")],
            arrays: ["elements": .object])
        let asset = RendererAsset(
            path: try .init(validating: "index.html"),
            digest: try RendererSHA256Digest(bytes: Array(repeating: 0, count: RendererSHA256Digest.byteCount)))
        let descriptor = try RendererDescriptor(
            reference: .init(
                packageID: try .init(validating: "org.example.bigjson"),
                version: try .init(validating: "1.0.0"),
                registrationID: try .init(validating: "bigjson")),
            displayName: "Big JSON",
            implementation: .webPackage(.init(path: asset.path)),
            matchers: [
                .normalizedMIME(canonical),
                .normalizedMIME(alias),
                .extensionFallback(ext),
                .boundedJSON(constraints),
            ],
            sourceType: .init(canonicalMIMEType: canonical, mimeAliases: [alias], filenameExtensions: [ext]),
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow],
            hasExplicitEmbeddingRoles: true,
            approvedAssets: [asset],
            capabilities: [.inputRead],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 0)
        return RegisteredRendererSourceTypes(descriptors: [descriptor])
    }
}

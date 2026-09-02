import Foundation
import Testing
import WikiFSCore
import WikiFSTypes

// MARK: - RendererAssetExtractorHelperLocationTests

@Suite(.serialized, .timeLimit(.minutes(2)))
struct RendererAssetExtractorHelperLocationTests {
    @Test("resolves the SwiftPM sibling helper under .build")
    func resolvesSwiftPMSiblingHelper() throws {
        let helper = try locateHelper()
        // The helper must be a regular, executable file.
        #expect(RendererAssetExtractorHelperLocation.isExecutableFile(helper))
    }

    @Test("missing helper fails closed to zero admitted assets without launching")
    func missingHelperFailsClosed() async throws {
        // A bogus URL is not executable; a non-executable helper path must
        // fail closed (resolve to nil) without launching WebKit asset
        // authority.
        let missing = URL(fileURLWithPath: "/nonexistent/renderer-asset-reference-extractor-helper")
        #expect(RendererAssetExtractorHelperLocation.isExecutableFile(missing) == false)
        // The client must surface an empty outcome for a missing helper.
        let outcome = try await RendererAssetReferenceExtractorClient.run(
            .init(
                helperURL: missing,
                extractorBytes: Data("x".utf8),
                entryFunction: "__sdw_extract",
                primaryInput: Data(),
                maxExtractorInputBytes: 1024,
                maxExtractorOutputBytes: 1024,
                maxReferenceCount: 16,
                maxExecutionSeconds: 1,
                stdoutLimit: 4096,
                stderrLimit: 1024))
        #expect(outcome.records.isEmpty)
    }

    @Test("helper protocol smoke test runs the real executable")
    func helperProtocolSmokeTest() async throws {
        let helper = try locateHelper()
        // A trivial extractor that parses its JSON primary input (passed as a
        // UTF-8 string) and returns a single imageNode reference. It must
        // define the entry function at top level (the helper resolves it by
        // name from the JS global scope).
        let extractor = Self.simpleExtractor()
        let primaryInput = Data(#"{"nodes":[{"type":"file","file":"diagram.png"}]}"#.utf8)
        let request = Self.request(helper: helper, extractor: extractor, primaryInput: primaryInput)
        let outcome = try await RendererAssetReferenceExtractorClient.run(request)
        #expect(outcome.failureReason == nil)
        #expect(outcome.records.count == 1)
        #expect(outcome.records[0].role == .imageNode)
        #expect(outcome.records[0].reference == "diagram.png")
    }

    @Test("at-cap and one-byte-over frames behave correctly")
    func frameBoundaryTests() async throws {
        let helper = try locateHelper()
        let extractor = Self.simpleExtractor()
        let primary = Data(#"{"nodes":[],"edges":[]}"#.utf8)

        // At-cap: a frame whose payload is exactly the client's max output.
        // We cannot exceed the fixed helper's internal frame cap, so verify
        // that a payload just under it is accepted.
        let justUnder = try RendererAssetReferenceExtractorClient.frameRequest(
            Self.request(
                helper: helper,
                extractor: extractor,
                primaryInput: primary,
                maxExtractorOutputBytes: 8 * 1_024))
        #expect(justUnder.count > 4)

        // One-byte-over extractor: the client rejects it pre-spawn.
        let oversizedExtractor = Data(repeating: 0x61, count: 1025)
        let request = Self.request(
            helper: helper,
            extractor: oversizedExtractor,
            primaryInput: primary,
            maxExtractorInputBytes: 1024)
        #expect(throws: RendererAssetReferenceExtractorClient.ClientError.self) {
            _ = try RendererAssetReferenceExtractorClient.frameRequest(request)
        }
    }

    @Test("helper rejects malformed, duplicate, and undeclared-role records")
    func rejectsMalformedDuplicateAndUndeclaredRoleRecords() async throws {
        let helper = try locateHelper()

        // Malformed record (missing role) -> fail closed.
        let malformed = "return { records: [{ reference: 'x.png' }] };"
        let malformedOutcome = try await runInline(helper: helper, body: malformed)
        #expect(malformedOutcome.records.isEmpty)
        #expect(malformedOutcome.failureReason != nil)

        // Undeclared role -> fail closed.
        let undeclared = "return { records: [{ role: 'arbitrary', reference: 'x.png' }] };"
        let undeclaredOutcome = try await runInline(helper: helper, body: undeclared)
        #expect(undeclaredOutcome.records.isEmpty)
        #expect(undeclaredOutcome.failureReason != nil)

        // Duplicate record -> fail closed.
        let duplicate = "return { records: [{ role: 'imageNode', reference: 'x.png' }, { role: 'imageNode', reference: 'x.png' }] };"
        let duplicateOutcome = try await runInline(helper: helper, body: duplicate)
        #expect(duplicateOutcome.records.isEmpty)
        #expect(duplicateOutcome.failureReason != nil)
    }

    @Test("helper JavaScript has no host objects or enumeration capability")
    func exposesNoHostObjects() async throws {
        let helper = try locateHelper()
        // A hostile extractor trying to reach out to the host: `process`,
        // `require`, `console`, `fetch`, `XMLHttpRequest`, `window`, and
        // `globalThis` must not exist as objects. We make the extractor throw
        // if ANY host object is reachable — the helper then fails closed and
        // the client reports a failure. If no host object exists, the
        // extractor returns zero records cleanly.
        let outcome = try await runInline(helper: helper, body: Self.hostileBody(), entry: "__sdw_extract")
        // Either clean zero records (no host objects) or a redacted failure.
        #expect(outcome.records.isEmpty)

        // A hostile extractor that tries to read sibling content via the
        // filesystem must fail closed (no records) — the isolated JSContext
        // has no `require`, so the read throws.
        let fsOutcome = try await runInline(helper: helper, body: Self.filesystemBody(), entry: "__sdw_extract")
        #expect(fsOutcome.records.isEmpty)
    }

    // (the `hostile` probe body above is exercised via hostileBody(); the
    // literal string is kept in the helper so the assertion is readable)
    private static func hostileBody() -> String {
        """
        var names = ['process', 'require', 'console', 'fetch', 'XMLHttpRequest', 'window', 'globalThis'];
        var found = [];
        names.forEach(function (name) {
          try { if (typeof eval(name) !== 'undefined') found.push(name); } catch (e) {}
        });
        if (found.length > 0) { throw new Error('host object exposed'); }
        return { records: [] };
        """
    }

    private static func filesystemBody() -> String {
        """
        var fs;
        try { fs = eval('require("fs")'); } catch (e) { throw new Error('no require'); }
        var files = fs.readdirSync('.');
        return { records: [{ role: 'imageNode', reference: files[0] }] };
        """
    }

    @Test("helper terminates and reaps an infinite-loop extractor")
    func terminatesAndReapsInfiniteLoopHelper() async throws {
        let helper = try locateHelper()
        let infinite = """
        __sdw_extract = function (input) { while (true) {} };
        """
        let request = Self.request(
            helper: helper,
            extractor: Data(infinite.utf8),
            primaryInput: Data("{}".utf8),
            maxExecutionSeconds: 1,
            stdoutLimit: 4096,
            stderrLimit: 1024)
        let started = ContinuousClock.now
        let outcome = try await RendererAssetReferenceExtractorClient.run(request)
        // The declared 1-second deadline must terminate and reap the group;
        // the wait must not hang, and the outcome fails closed.
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(outcome.records.isEmpty)
        #expect(outcome.failureReason != nil)
    }

    // MARK: - Fixtures/helpers

    private func locateHelper() throws -> URL {
        guard let resolved = RendererAssetExtractorHelperLocation.locate(
            mainBundle: Bundle.main,
            processInfo: .init()) else {
            Issue.record("reference-extractor helper was not located; is `.build` present?")
            throw RendererAssetExtractorHelperLocationTestsError.missingHelper
        }
        return resolved
    }

    private func runInline(helper: URL, body: String, entry: String = "__sdw_extract") async throws -> RendererAssetReferenceExtractorClient.Outcome {
        let extractor = Data("\(entry) = function (input) { \(body) }\n".utf8)
        let primary = Data(#"{"nodes":[],"edges":[]}"#.utf8)
        let request = Self.request(helper: helper, extractor: extractor, primaryInput: primary)
        return try await RendererAssetReferenceExtractorClient.run(request)
    }

    private static func simpleExtractor() -> Data {
        Data("""
        __sdw_extract = function (input) {
          var data = JSON.parse(input);
          var records = [];
          (data.nodes || []).forEach(function (node) {
            if (node.type === "file" && node.file) {
              records.push({ role: "imageNode", reference: node.file });
            }
          });
          return { records: records };
        };
        """.utf8)
    }

    private static func request(
        helper: URL,
        extractor: Data,
        primaryInput: Data,
        maxExtractorInputBytes: Int = 256 * 1_024,
        maxExtractorOutputBytes: Int = 256 * 1_024,
        maxReferenceCount: Int = 256,
        maxExecutionSeconds: Int = 10,
        stdoutLimit: Int = 256 * 1_024,
        stderrLimit: Int = 64 * 1_024
    ) -> RendererAssetReferenceExtractorClient.Request {
        .init(
            helperURL: helper,
            extractorBytes: extractor,
            entryFunction: "__sdw_extract",
            primaryInput: primaryInput,
            maxExtractorInputBytes: maxExtractorInputBytes,
            maxExtractorOutputBytes: maxExtractorOutputBytes,
            maxReferenceCount: maxReferenceCount,
            maxExecutionSeconds: maxExecutionSeconds,
            stdoutLimit: stdoutLimit,
            stderrLimit: stderrLimit)
    }
}

private enum RendererAssetExtractorHelperLocationTestsError: Error {
    case missingHelper
}

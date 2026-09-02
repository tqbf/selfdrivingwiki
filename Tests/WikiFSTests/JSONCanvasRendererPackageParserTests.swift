import Foundation
import Testing
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Normal-suite execution of the JSON Canvas package parser. It runs the exact
/// `__sdw_parse_canvas` entry that `viewer.js` exposes (the same function the
/// package renderer calls) inside a fresh JavaScriptCore context — mandatory,
/// Node-free, no DOM/filesystem/network/native objects. This replaces the old
/// `nodeAvailable`/`Thread.sleep` optional node-subprocess path with a
/// deterministic in-process JSC evaluation that FAILS (not skips) when the
/// asset or entry is unavailable.
#if canImport(JavaScriptCore)
@Suite(.serialized, .timeLimit(.minutes(2)))
struct JSONCanvasRendererPackageParserTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("RendererPackages/JSONCanvas", isDirectory: true)

    @Test("JavaScriptCore harness executes the package parser entry")
    func jscHarnessExecutesPackageParserEntry() throws {
        let runner = try Self.loadRunner()
        let result = try runner.parse(Data(Self.validCanvas.utf8))
        #expect(result.ok)
        #expect(result.nodes == 2)
        #expect(result.edges == 1)
    }

    @Test("parser accepts canvas at the declared cap and rejects one byte over")
    func acceptsAtPackageCapAndRejectsOneByteOverCap() throws {
        let runner = try Self.loadRunner()
        let target = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let cap = 48_000
        let padding = cap - target.count
        let atCap = target + Data(repeating: 0x20, count: padding)
        let overCap = target + Data(repeating: 0x20, count: padding + 1)

        #expect(try runner.parse(atCap).ok)
        let over = try runner.parse(overCap)
        #expect(over.ok == false)
    }

    @Test("parser rejects malformed, bounded, and unsafe documents")
    func rejectsMalformedBoundedAndUnsafeDocuments() throws {
        let runner = try Self.loadRunner()
        let textNode = #"{"id":"note","type":"text","x":0,"y":0,"width":120,"height":60,"text":"Note"}"#
        let edge = #"{"id":"edge","fromNode":"note","toNode":"note2"}"#
        let malformed = Data("{\"nodes\":[]".utf8)
        let unknownEndpoint = Data("{\"nodes\":[\(textNode)],\"edges\":[\(edge)]}".utf8)
        let traversal = Data(#"""{"nodes":[{"id":"file","type":"file","x":0,"y":0,"width":120,"height":60,"file":"../secret"}],"edges":[]}"""#.utf8)
        let scheme = Data(#"""{"nodes":[{"id":"file","type":"file","x":0,"y":0,"width":120,"height":60,"file":"https:example"}],"edges":[]}"""#.utf8)
        let percent = Data(#"""{"nodes":[{"id":"file","type":"file","x":0,"y":0,"width":120,"height":60,"file":"a%2Fb"}],"edges":[]}"""#.utf8)
        let oversizeText = Data(#"""{"nodes":[{"id":"note","type":"text","x":0,"y":0,"width":120,"height":60,"text":"""#.utf8)
            + Data("\"\(String(repeating: "x", count: 8_193))\"".utf8)
            + Data(#"""}],"edges":[]}"""#.utf8)
        // Unknown node types and closed-field violations.
        let unknownType = Data(#"{"nodes":[{"id":"n","type":"table","x":0,"y":0,"width":10,"height":10}],"edges":[]}"#.utf8)
        let invalidSide = Data(#"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10,"text":"x"},{"id":"b","type":"text","x":20,"y":0,"width":10,"height":10,"text":"y"}],"edges":[{"id":"e","fromNode":"a","toNode":"b","fromSide":"diagonal"}]}"#.utf8)
        let invalidEnd = Data(#"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10,"text":"x"},{"id":"b","type":"text","x":20,"y":0,"width":10,"height":10,"text":"y"}],"edges":[{"id":"e","fromNode":"a","toNode":"b","fromEnd":"circle"}]}"#.utf8)
        let invalidBackgroundStyle = Data(#"{"nodes":[{"id":"g","type":"group","x":0,"y":0,"width":10,"height":10,"label":"g","background":"bg.png","backgroundStyle":"stretch"}],"edges":[]}"#.utf8)

        // A canvas with nodes but no edges is VALID per JSON Canvas 1.0 (both
        // top-level arrays are optional).
        let noEdges = Data("{\"nodes\":[\(textNode)]}".utf8)
        #expect(try runner.parse(noEdges).ok)

        for (label, payload) in [
            ("malformed", malformed),
            ("unknownEndpoint", unknownEndpoint), ("traversal", traversal),
            ("scheme", scheme), ("percent", percent), ("oversizeText", oversizeText),
            ("unknownType", unknownType), ("invalidSide", invalidSide),
            ("invalidEnd", invalidEnd), ("invalidBackgroundStyle", invalidBackgroundStyle),
        ] {
            let result = try runner.parse(payload)
            #expect(result.ok == false, "expected rejection for \(label)")
        }

        // Groups are supported.
        let groupValid = Data("{\"nodes\":[{\"id\":\"g\",\"type\":\"group\",\"x\":0,\"y\":0,\"width\":200,\"height\":100,\"label\":\"Group\",\"background\":\"bg.png\",\"backgroundStyle\":\"cover\"}],\"edges\":[]}".utf8)
        #expect(try runner.parse(groupValid).ok)

        // Unknown top-level properties are ignored (forward-compatible).
        let unknownTopLevel = Data("{\"nodes\":[],\"edges\":[],\"vendor\":{\"custom\":true}}".utf8)
        #expect(try runner.parse(unknownTopLevel).ok)
    }

    // MARK: - Helpers

    private static var validCanvas: String {
        #"{"nodes":[{"id":"note","type":"text","x":20,"y":10,"width":160,"height":80,"text":"First note"},{"id":"note2","type":"text","x":220,"y":10,"width":160,"height":80,"text":"Second note"}],"edges":[{"id":"edge","fromNode":"note","toNode":"note2"}]}"#
    }

    private static func loadRunner() throws -> ParserRunner {
        let viewerURL = packageRoot.appendingPathComponent("viewer.js")
        let sourceData = try Data(contentsOf: viewerURL)
        guard let source = String(data: sourceData, encoding: .utf8) else {
            throw ParserHarnessError.missingAsset
        }
        return try ParserRunner(viewerSource: source)
    }
}

struct ParseOutcome {
    let ok: Bool
    let nodes: Int
    let edges: Int
}

// Thread-confined: one ParserRunner per test, suite serialized — the same
// invariant as FenceSyntaxValidator (each runner uses its JSContext on one
// thread at a time).
// swiftlint:disable:next unchecked_sendable
private final class ParserRunner: @unchecked Sendable {
    private let context: JSContext

    init(viewerSource: String) throws {
        guard let context = JSContext() else { throw ParserHarnessError.contextUnavailable }
        context.exceptionHandler = { _, _ in }
        context.evaluateScript(viewerSource)
        self.context = context
    }

    func parse(_ payload: Data) throws -> ParseOutcome {
        guard let fn = context.objectForKeyedSubscript("__sdw_parse_canvas" as NSString), fn.isObject else {
            throw ParserHarnessError.entryUnavailable
        }
        let base64 = payload.base64EncodedString()
        guard let result = fn.call(withArguments: [base64]),
              let text = result.toString() else {
            throw ParserHarnessError.malformedResult
        }
        guard let data = text.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParserHarnessError.malformedResult
        }
        let ok = (dict["ok"] as? Bool) ?? false
        let nodes = (dict["nodes"] as? Int) ?? 0
        let edges = (dict["edges"] as? Int) ?? 0
        return ParseOutcome(ok: ok, nodes: nodes, edges: edges)
    }
}

private enum ParserHarnessError: Error, CustomStringConvertible {
    case missingAsset
    case contextUnavailable
    case entryUnavailable
    case malformedResult

    var description: String {
        switch self {
        case .missingAsset: "viewer.js is missing or not readable"
        case .contextUnavailable: "JavaScriptCore context unavailable"
        case .entryUnavailable: "package parser entry __sdw_parse_canvas is unavailable"
        case .malformedResult: "package parser entry returned a malformed result"
        }
    }
}

#else
@Suite(.serialized, .timeLimit(.minutes(2)))
struct JSONCanvasRendererPackageParserTests {
    @Test("JavaScriptCore is required for the JSON Canvas parser harness")
    func requiresJavaScriptCore() throws {
        Issue.record("JavaScriptCore is unavailable; JSON Canvas parser harness cannot run.")
    }
}
#endif

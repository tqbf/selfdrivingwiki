import Foundation
import Testing
import WikiFSTypes
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

// MARK: - JSONCanvasJavaScriptHarnessTests

/// Mandatory, Node-free JavaScriptCore harness for the JSON Canvas package's
/// pure scene-model stages. It loads the exact package-owned viewer.js in a
/// fresh JSContext with NO DOM, filesystem, network, or native objects, and
/// executes the package's pure test seam (`__sdw_scene`, `__sdw_edge`,
/// `__sdw_layout_text`, `__sdw_resolve_assets`, `__sdw_parse_edges`).
///
/// The harness FAILS, not skips, when the asset or entry function is
/// unavailable. This replaces the old `nodeAvailable`/`Thread.sleep` optional
/// node-subprocess path with a deterministic in-process JSC evaluation.
#if canImport(JavaScriptCore)
@Suite(.serialized, .timeLimit(.minutes(2)))
struct JSONCanvasJavaScriptHarnessTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("RendererPackages/JSONCanvas", isDirectory: true)

    @Test("executes the required scene model without optional skip")
    func executesRequiredSceneModelWithoutOptionalSkip() throws {
        let runner = try loadRunner()
        // If the asset or entry function is unavailable, this throws (fail,
        // not skip). The scene must return deterministic bounds.
        let result = try runner.call("scene", arg: JSONCanvasFixtures.twoNodes)
        let value = try decodeObject(result)
        let bounds = try #require(value["bounds"] as? [String: Double])
        #expect(bounds["x"] == 0)
        #expect(bounds["right"] == 300)
    }

    @Test("scene bounds include negative coordinates and wide separations")
    func computesFullSceneBounds() throws {
        let runner = try loadRunner()
        let result = try runner.call("scene", arg: JSONCanvasFixtures.negativeAndWide)
        let value = try decodeObject(result)
        let bounds = try #require(value["bounds"] as? [String: Double])
        #expect(bounds["x"] == -300)
        #expect(bounds["y"] == -200)
        #expect(bounds["right"] == 1960)
        #expect(bounds["bottom"] == 480)
    }

    @Test("edge geometry honors explicit sides at rectangle boundaries")
    func honorsExplicitSidesAtRectangleBoundaries() throws {
        let runner = try loadRunner()
        // Horizontal edge: a right side, b left side.
        let result = try runner.call("edge", args: [JSONCanvasFixtures.twoNodes, "a", "b", "right", "left"])
        let value = try decodeObject(result)
        let from = try #require(value["from"] as? [String: Double])
        let to = try #require(value["to"] as? [String: Double])
        #expect(from["x"] == 100)   // a's right boundary
        #expect(from["y"] == 25)    // a's vertical center
        #expect(to["x"] == 200)     // b's left boundary
        #expect(to["y"] == 25)
        // The path is a cubic Bezier from right to left.
        let path = value["path"] as? String
        #expect(path?.hasPrefix("M 100 25 C") == true)
    }

    @Test("edge geometry applies automatic sides deterministically")
    func appliesAutomaticSidesDeterministically() throws {
        let runner = try loadRunner()
        // No sides: automatic selection faces the other node.
        let result = try runner.call("edge", args: [JSONCanvasFixtures.twoNodes, "a", "b", nil, nil])
        let value = try decodeObject(result)
        let from = try #require(value["from"] as? [String: Double])
        let to = try #require(value["to"] as? [String: Double])
        #expect(from["x"] == 100)  // a's right (faces b)
        #expect(to["x"] == 200)    // b's left
        // Vertical edge: top/bottom automatic.
        let verticalFixture = JSONCanvasFixtures.nodesOnly("a", "b", atY: true)
        let vResult = try runner.call("edge", args: [verticalFixture, "a", "b", nil, nil])
        let vValue = try decodeObject(vResult)
        let vFrom = try #require(vValue["from"] as? [String: Double])
        let vTo = try #require(vValue["to"] as? [String: Double])
        #expect(vFrom["y"] == 50)   // a's bottom (faces b below)
        #expect(vTo["y"] == 150)    // b's top
    }

    @Test("JSON Canvas endpoint defaults apply: fromEnd none, toEnd arrow")
    func appliesJSONCanvasEndpointDefaults() throws {
        let runner = try loadRunner()
        let result = try runner.call("parseEdges", arg: JSONCanvasFixtures.twoNodes)
        let value = try decodeArray(result)
        let edge = try #require(value.first as? [String: Any])
        #expect(edge["fromEnd"] as? String == "none")
        #expect(edge["toEnd"] as? String == "arrow")
    }

    @Test("all fromEnd/toEnd/fromSide/toSide combinations parse")
    func parsesAllSideAndEndCombinations() throws {
        let runner = try loadRunner()
        let result = try runner.call("parseEdges", arg: JSONCanvasFixtures.sideAndEndCombinations)
        let value = try decodeArray(result)
        #expect(value.count == 3)
        let first = try #require(value[0] as? [String: Any])
        #expect(first["fromSide"] as? String == "right")
        #expect(first["toSide"] as? String == "left")
        #expect(first["fromEnd"] as? String == "none")
        #expect(first["toEnd"] as? String == "arrow")
        let second = try #require(value[1] as? [String: Any])
        #expect(second["fromEnd"] as? String == "arrow")
        #expect(second["toEnd"] as? String == "none")
        let third = try #require(value[2] as? [String: Any])
        #expect(third["fromEnd"] as? String == "none")
        #expect(third["toEnd"] as? String == "none")
    }

    @Test("Markdown text wraps within bounds and clips with an overflow cue")
    func wrapsAndClipsText() throws {
        let runner = try loadRunner()
        // The layoutText seam takes raw markdown + width + height. Use a text
        // long enough to overflow a 90px node (~5 lines at lineHeight 16).
        let long = "First line of the node that is quite long.\\nSecond paragraph line two.\\nThird paragraph line three.\\nFourth line.\\nFifth line.\\nSixth line overflows."
        let markdown = long.replacingOccurrences(of: "\\n", with: "\n")
        let result = try runner.call("layoutText", args: [markdown, 180, 90])
        let value = try decodeObject(result)
        let lines = value["lines"] as? [[[String: Any]]]
        let overflow = value["overflow"] as? Bool
        #expect(lines?.isEmpty == false)
        #expect(lines?.first?.isEmpty == false)
        // First token is plain text (the long fixture has no Markdown).
        let firstToken = lines?.first?.first
        #expect(firstToken?["type"] as? String == "text")
        // The long Markdown clips to node height with an overflow cue.
        #expect(overflow == true)
    }

    @Test("preserves node z-order and colors in scene model")
    func preservesZOrderAndColors() throws {
        let runner = try loadRunner()
        // allColors has 7 nodes + 1 colored edge; the scene bounds span them.
        let result = try runner.call("scene", arg: JSONCanvasFixtures.allColors)
        let value = try decodeObject(result)
        #expect(value["nodeCount"] as? Int == 7)
    }

    @Test("image nodes and group backgrounds resolve only relative references")
    func resolvesImageAndBackgroundAssets() throws {
        let runner = try loadRunner()
        let result = try runner.call("resolveAssets", arg: JSONCanvasFixtures.imageNodes)
        let value = try decodeObject(result)
        let requests = try #require(value["requests"] as? [[String: String]])
        let references = requests.compactMap { $0["reference"] }
        #expect(references.contains("img/png.png"))
        #expect(references.contains("img/svg.svg"))
        #expect(references.contains("img/webp.webp"))
        #expect(references.contains("img/bg.png")) // group background (cover/ratio/repeat)
        // A parse-valid missing/unsupported reference IS a valid request
        // (the host denies it at admission, and the viewer falls back).
        let unavailable = try runner.call("resolveAssets", arg: JSONCanvasFixtures.unavailableAttachments)
        let unavailableValue = try decodeObject(unavailable)
        let unavailableRequests = try #require(unavailableValue["requests"] as? [[String: String]])
        let unavailableRefs = unavailableRequests.compactMap { $0["reference"] }
        #expect(unavailableRefs.contains("missing.png"))   // valid request, host-denied
        #expect(unavailableRefs.contains("notes.txt"))     // valid request, host-denied
    }

    @Test("strict parser rejects traversal and scheme file references")
    func rejectsTraversalAndSchemeReferences() throws {
        let runner = try loadRunner()
        // The whole canvas fails closed on an invalid file reference.
        let result = try runner.call("parseCanvas", arg: JSONCanvasFixtures.invalidFileReferences)
        let value = try decodeObject(result)
        #expect((value["ok"] as? Bool) == false)
    }

    // MARK: - JSC harness

    private func loadRunner() throws -> JSCRunner {
        let viewerURL = Self.packageRoot.appendingPathComponent("viewer.js")
        let sourceData = try Data(contentsOf: viewerURL)
        guard let source = String(data: sourceData, encoding: .utf8) else {
            throw JSONCanvasHarnessError.missingAsset("viewer.js is not readable")
        }
        return try JSCRunner(viewerSource: source)
    }

    /// The package seams return JSON strings; parse them into Swift objects.
    private func decodeObject(_ result: JSValue) throws -> [String: Any] {
        let text = try stringResult(result)
        guard let data = text.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSONCanvasHarnessError.malformedResult
        }
        return dict
    }

    private func decodeArray(_ result: JSValue) throws -> [Any] {
        let text = try stringResult(result)
        guard let data = text.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw JSONCanvasHarnessError.malformedResult
        }
        return array
    }

    private func stringResult(_ result: JSValue) throws -> String {
        guard let text = result.toString() else { throw JSONCanvasHarnessError.malformedResult }
        return text
    }
}

/// Executes the package's pure seam functions in a fresh JSContext. No DOM,
/// filesystem, network, or native objects are bridged. JSValue/JSContext are
/// thread-confined: each runner is created and used by exactly one test, and
/// the suite is serialized, so no two threads ever touch the same context.
// swiftlint:disable:next unchecked_sendable
private final class JSCRunner: @unchecked Sendable {
    private let context: JSContext

    init(viewerSource: String) throws {
        guard let context = JSContext() else {
            throw JSONCanvasHarnessError.contextUnavailable
        }
        context.exceptionHandler = { _, _ in }
        // No `console` bridged: a stray log would throw a ReferenceError,
        // surfacing as a malformed result (fail closed).
        context.evaluateScript(viewerSource)
        self.context = context
    }

    func call(_ function: String, arg: String) throws -> JSValue {
        try call(function, args: [arg])
    }

    func call(_ function: String, args: [Any?]) throws -> JSValue {
        // Map harness names to the package's global seam names (which use
        // underscores: __sdw_scene, __sdw_edge, __sdw_layout_text,
        // __sdw_resolve_assets, __sdw_parse_edges, __sdw_parse_canvas).
        let globalName: String
        switch function {
        case "parseCanvas": globalName = "__sdw_parse_canvas"
        case "scene": globalName = "__sdw_scene"
        case "edge": globalName = "__sdw_edge"
        case "layoutText": globalName = "__sdw_layout_text"
        case "resolveAssets": globalName = "__sdw_resolve_assets"
        case "parseEdges": globalName = "__sdw_parse_edges"
        default: globalName = "__sdw_\(function)"
        }
        guard let fn = context.objectForKeyedSubscript(globalName as NSString),
              fn.isObject else {
            throw JSONCanvasHarnessError.entryFunctionUnavailable(globalName)
        }
        let arguments = args.map { (value: Any?) -> JSValue in
            if let value { return JSValue(object: value, in: context) }
            return JSValue(nullIn: context)
        }
        guard let result = fn.call(withArguments: arguments) else {
            throw JSONCanvasHarnessError.malformedResult
        }
        return result
    }
}

private enum JSONCanvasHarnessError: Error, CustomStringConvertible {
    case missingAsset(String)
    case contextUnavailable
    case entryFunctionUnavailable(String)
    case malformedResult

    var description: String {
        switch self {
        case let .missingAsset(what): what
        case .contextUnavailable: "JavaScriptCore context unavailable"
        case let .entryFunctionUnavailable(name): "package test seam \(name) is unavailable"
        case .malformedResult: "package test seam returned a malformed result"
        }
    }
}

extension JSONCanvasFixtures {
    /// Two text nodes one above the other (vertical automatic sides).
    static func nodesOnly(_ idA: String, _ idB: String, atY: Bool) -> String {
        if atY {
            return """
            {"nodes":[{"id":"\(idA)","type":"text","x":0,"y":0,"width":100,"height":50,"text":"A"},
                      {"id":"\(idB)","type":"text","x":0,"y":150,"width":100,"height":50,"text":"B"}],"edges":[]}
            """
        }
        return """
        {"nodes":[{"id":"\(idA)","type":"text","x":0,"y":0,"width":100,"height":50,"text":"A"},
                  {"id":"\(idB)","type":"text","x":200,"y":0,"width":100,"height":50,"text":"B"}],"edges":[]}
        """
    }
}

#else
// Linux stub: JavaScriptCore is unavailable; the suite fails closed rather
// than silently skipping — this renderer-format correctness is a macOS gate.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct JSONCanvasJavaScriptHarnessTests {
    @Test("JavaScriptCore is required for the JSON Canvas harness")
    func requiresJavaScriptCore() throws {
        Issue.record("JavaScriptCore is unavailable; JSON Canvas scene-model harness cannot run.")
    }
}
#endif

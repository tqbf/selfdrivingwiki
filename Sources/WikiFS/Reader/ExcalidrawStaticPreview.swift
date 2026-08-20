import Foundation
import WikiFSMarkdown

// pattern: Functional Core — bytes in, markup out, no host state.

/// A bounded, host-generated SVG preview of an Excalidraw drawing.
///
/// The reader's renderer card is a static surface: it may not run the package's
/// JavaScript, so the card draws the drawing itself. This covers the same
/// element subset the bundled viewer does, which is enough to recognise a
/// diagram at a glance; the Interact control still opens the real renderer for
/// panning, zooming, and links.
///
/// Pure and nonisolated by construction — Markdown conversion runs off the main
/// actor, so this takes bytes and returns markup with no store and no actor.
///
/// Two rules keep author-controlled JSON safe in reader HTML: every colour must
/// match a strict hex form before it reaches an attribute, and an element's
/// `link` is deliberately dropped. The interactive viewer wraps a linked shape
/// in an `<a>`; the reader must never take an `href` from a fence.
enum ExcalidrawStaticPreview {
    /// Enough to draw a real diagram, few enough that a pathological document
    /// cannot bloat the page. Input is already bounded to 48 KB upstream.
    static let maximumElementCount = 400

    /// Excalidraw's own default canvas. A drawing's colours were chosen against
    /// its canvas, so the preview always paints one — near-black strokes on the
    /// reader's dark background would otherwise be invisible.
    static let defaultBackground = "#ffffff"
    static let defaultStroke = "#1e1e1e"

    static let padding = 12.0
    static let defaultFontSize = 16.0
    static let defaultStrokeWidth = 2.0
    static let cornerRadius = 8.0

    /// Returns the SVG for a valid drawing, or nil when the bytes are not a
    /// drawing this can render. A nil result leaves the card intact and silent
    /// rather than claiming a preview it cannot produce.
    static func svg(from bytes: Data) -> String? {
        // A fence whose JSON does not parse is an ordinary authoring state, not
        // a host failure: the card still renders and Interact still opens the
        // renderer, which reports the real problem. Conversion re-runs on every
        // render, so logging here would repeat for every keystroke.
        // swiftlint:disable:next silent_try_optional
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              root["type"] as? String == "excalidraw",
              let rawElements = root["elements"] as? [[String: Any]]
        else { return nil }

        let elements = rawElements
            .filter { $0["isDeleted"] as? Bool != true }
            .prefix(maximumElementCount)
        let shapes = elements.compactMap(shape(for:))
        guard shapes.isEmpty == false, let box = bounds(of: elements) else { return nil }

        let originX = box.minX - padding
        let originY = box.minY - padding
        let width = box.width + padding * 2
        let height = box.height + padding * 2
        let canvas = tag("rect", [
            ("x", number(originX)), ("y", number(originY)),
            ("width", number(width)), ("height", number(height)),
            ("fill", color(root["appState"] as? [String: Any]) ?? defaultBackground),
        ])
        let viewBox = [originX, originY, width, height].map(number).joined(separator: " ")
        return tag(
            "svg",
            [
                ("viewBox", viewBox),
                ("role", "img"),
                ("aria-label", "Preview of an Excalidraw drawing"),
                ("preserveAspectRatio", "xMidYMid meet"),
            ],
            content: canvas + shapes.joined())
    }

    // MARK: Geometry

    private struct Box {
        var minX: Double
        var minY: Double
        var width: Double
        var height: Double
    }

    private static func bounds(of elements: some Sequence<[String: Any]>) -> Box? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for element in elements {
            guard let x = numeric(element["x"]), let y = numeric(element["y"]) else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x + (numeric(element["width"]) ?? 0))
            maxY = max(maxY, y + (numeric(element["height"]) ?? 0))
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }
        // A single point or a flat connector still needs a drawable box.
        return Box(minX: minX, minY: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    // MARK: Elements

    private static func shape(for element: [String: Any]) -> String? {
        guard let x = numeric(element["x"]), let y = numeric(element["y"]) else { return nil }
        let width = max(0, numeric(element["width"]) ?? 0)
        let height = max(0, numeric(element["height"]) ?? 0)
        let stroke = color(element["strokeColor"]) ?? defaultStroke
        let strokeWidth = number(numeric(element["strokeWidth"]) ?? defaultStrokeWidth)
        let outline = [
            ("fill", color(element["backgroundColor"]) ?? "none"),
            ("stroke", stroke),
            ("stroke-width", strokeWidth),
        ] + opacity(element)

        switch element["type"] as? String {
        case "rectangle":
            let radius = element["roundness"] is [String: Any] ? cornerRadius : 0
            return tag("rect", [
                ("x", number(x)), ("y", number(y)),
                ("width", number(width)), ("height", number(height)),
                ("rx", number(radius)),
            ] + outline)
        case "ellipse":
            return tag("ellipse", [
                ("cx", number(x + width / 2)), ("cy", number(y + height / 2)),
                ("rx", number(width / 2)), ("ry", number(height / 2)),
            ] + outline)
        case "diamond":
            let corners = [
                (x + width / 2, y), (x + width, y + height / 2),
                (x + width / 2, y + height), (x, y + height / 2),
            ]
            return tag("polygon", [("points", points(corners))] + outline)
        case "line", "arrow", "freedraw":
            guard let plotted = polyline(of: element, originX: x, originY: y) else { return nil }
            return tag("polyline", [
                ("points", points(plotted)), ("fill", "none"),
                ("stroke", stroke), ("stroke-width", strokeWidth),
            ] + opacity(element))
        case "text":
            guard let text = element["text"] as? String, text.isEmpty == false else { return nil }
            return tag(
                "text",
                [
                    ("x", number(x)), ("y", number(y)), ("fill", stroke),
                    ("font-size", number(numeric(element["fontSize"]) ?? defaultFontSize)),
                    ("dominant-baseline", "hanging"),
                    ("font-family", "-apple-system, BlinkMacSystemFont, sans-serif"),
                ] + opacity(element),
                content: HTMLEntities.escapeHTML(text))
        default:
            return nil
        }
    }

    /// Connector points are stored relative to the element's origin.
    private static func polyline(
        of element: [String: Any],
        originX: Double,
        originY: Double
    ) -> [(Double, Double)]? {
        guard let raw = element["points"] as? [[Any]] else { return nil }
        let plotted = raw.compactMap { pair -> (Double, Double)? in
            guard pair.count >= 2, let dx = numeric(pair[0]), let dy = numeric(pair[1])
            else { return nil }
            return (originX + dx, originY + dy)
        }
        return plotted.count >= 2 ? plotted : nil
    }

    private static func opacity(_ element: [String: Any]) -> [(String, String)] {
        // Excalidraw stores opacity as a percentage.
        guard let value = numeric(element["opacity"]), value >= 0, value < 100 else { return [] }
        return [("opacity", number(value / 100))]
    }

    private static func points(_ values: [(Double, Double)]) -> String {
        values.map { "\(number($0.0)),\(number($0.1))" }.joined(separator: " ")
    }

    // MARK: Markup

    /// Attribute values come from validated numbers, fixed keywords, and
    /// hex colours only, so they need no further escaping; element text is
    /// escaped by the caller.
    private static func tag(
        _ name: String,
        _ attributes: [(String, String)],
        content: String? = nil
    ) -> String {
        let rendered = attributes.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
        guard let content else { return "<\(name) \(rendered)/>" }
        return "<\(name) \(rendered)>\(content)</\(name)>"
    }

    // MARK: Scalars

    /// Only `#rgb` and `#rrggbb` reach an attribute. Anything else — including
    /// Excalidraw's `"transparent"` — is treated as absent by the caller.
    private static func color(_ value: Any?) -> String? {
        guard let text = value as? String, text.hasPrefix("#") else { return nil }
        let digits = text.dropFirst()
        guard digits.count == 3 || digits.count == 6,
              digits.allSatisfy(\.isHexDigit)
        else { return nil }
        return text
    }

    private static func color(_ appState: [String: Any]?) -> String? {
        color(appState?["viewBackgroundColor"])
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let value = value as? Double { return value.isFinite ? value : nil }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 100).rounded() / 100
        guard rounded != rounded.rounded(), abs(rounded) < 1e9 else {
            return String(Int(rounded.rounded()))
        }
        return String(rounded)
    }
}

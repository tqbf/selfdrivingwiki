import Foundation

/// A format-agnostic timed-text parser that converts YouTube's timedtext XML,
/// YouTube's JSON3 caption format, WebVTT (`.vtt`), and SRT (`.srt`) subtitles
/// into a shared cue model, then renders clean markdown.
///
/// This generalizes `TTMLTranscript` (Apple Podcasts): Apple TTML, YouTube
/// XML/JSON3, WebVTT, and SRT all reduce to "timed text cues → markdown."
/// The parser is PURE (`XMLParser` / `JSONSerialization` / line splitting over
/// in-memory bytes — no network), so it is unit-tested against fixtures trimmed
/// from real caption files. Issue #564.
///
/// YouTube's timedtext XML escapes HTML entities (`&amp;`, `&#39;`, `&quot;`);
/// `XMLParser` decodes them automatically. YouTube's JSON3 nests segments under
/// `events[].segs[].utf8`. WebVTT/SRT split timing (`00:01:23.456 --> 00:01:25.789`)
/// from the text below it.
///
/// Output: one paragraph per **paragraph group** — cues are concatenated across
/// short gaps (the auto-generated ASR track fragments mid-sentence, so joining
/// with spaces inside a paragraph and breaking only on a meaningful time gap
/// produces readable prose, not one-word-per-line noise).
public struct TimedTextTranscript: Equatable, Sendable {

    /// One timed text cue: start/end time, optional speaker, text.
    /// Mirrors `TTMLTranscript.Cue` so downstream consumers are shape-compatible.
    public struct Cue: Equatable, Sendable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let speaker: String?
        public let text: String

        public init(start: TimeInterval, end: TimeInterval, speaker: String?, text: String) {
            self.start = start
            self.end = end
            self.speaker = speaker
            self.text = text
        }
    }

    public let cues: [Cue]

    public init(cues: [Cue]) {
        self.cues = cues
    }

    // MARK: - Parsing

    /// The supported source formats, auto-detected from the bytes.
    public enum Format: String, Sendable {
        case timedtextXML   // YouTube `<transcript><text start dur>…`
        case json3          // YouTube `{"events":[{tStartMs,segs:[{utf8}]}]}`
        case webVTT         // `WEBVTT` header + `HH:MM:SS.mmm --> …` cues
        case srt            // `1\nHH:MM:SS,mmm --> …` cues
    }

    /// Detect the format from the leading bytes, then dispatch to the matching
    /// parser. Throws `TimedTextError.parseFailed` when no cues can be extracted.
    public static func parse(_ data: Data) throws -> TimedTextTranscript {
        try parse(data, format: detectFormat(data))
    }

    /// Parse a known format (bypasses detection). Tests drive this directly.
    public static func parse(_ data: Data, format: Format) throws -> TimedTextTranscript {
        let cues: [Cue]
        switch format {
        case .timedtextXML: cues = try parseTimedtextXML(data)
        case .json3:         cues = try parseJSON3(data)
        case .webVTT:        cues = parseWebVTT(data)
        case .srt:           cues = parseSRT(data)
        }
        guard !cues.isEmpty else { throw TimedTextError.parseFailed }
        return TimedTextTranscript(cues: cues)
    }

    /// Sniff the leading bytes to pick a format. Order matters: the JSON3 and
    /// WebVTT/SRT signatures are unambiguous from the first non-whitespace chars;
    /// XML is detected by a leading `<` (and may be the timedtext root or a
    /// standalone `<text>` dump).
    public static func detectFormat(_ data: Data) -> Format {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return .srt
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .srt }
        // JSON3 starts with `{` and references `"events"`.
        if trimmed.first == "{" { return .json3 }
        // WebVTT starts with `WEBVTT`.
        if trimmed.hasPrefix("WEBVTT") { return .webVTT }
        // XML starts with `<`.
        if trimmed.first == "<" { return .timedtextXML }
        // SRT begins with an index `1` then a newline + `HH:MM:SS,mmm -->`.
        return .srt
    }

    // MARK: - Markdown rendering

    /// The transcript as readable markdown: cues grouped into paragraphs by a
    /// meaningful silence gap (default 2.0 s), with each group's joined by
    /// spaces. Paragraphs separated by blank lines. Speaker-prefixed
    /// (`SPEAKER: …`) when a cue carries one.
    public func plainText(paragraphGap: TimeInterval = 2.0) -> String {
        groupedParagraphs(gap: paragraphGap)
            .map { para in Self.cueTexts(para).joined(separator: " ") }
            .joined(separator: "\n\n")
    }

    /// Markdown with a `<!-- [mm:ss] -->` timestamp marker before each
    /// paragraph, so `[[source:…#"quote"]]` can anchor to a precise moment.
    public var markedText: String {
        groupedParagraphs(gap: 2.0)
            .map { para -> String in
            let start = para.first?.start ?? 0
            return "<!-- \(Self.timestampClock(start)) -->\n"
                + Self.cueTexts(para).joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    /// Render a paragraph's cues to text strings, prefixing the speaker when present
    /// (`SPEAKER: …`), mirroring `TTMLTranscript.plainText`.
    private static func cueTexts(_ cues: [Cue]) -> [String] {
        cues.map { cue in cue.speaker.map { "\($0): \(cue.text)" } ?? cue.text }
    }

    /// Group cues into paragraphs: consecutive cues whose gap (next.start -
    /// prev.end) is ≤ `gap` land in the same paragraph; a larger gap starts a
    /// new one. Empty-text cues are skipped. A speaker change also starts a new
    /// paragraph (so dialogue reads cleanly).
    func groupedParagraphs(gap: TimeInterval) -> [[Cue]] {
        var paragraphs: [[Cue]] = []
        var current: [Cue] = []
        var prevSpeaker: String?
        for cue in cues where !cue.text.isEmpty {
            if let last = current.last {
                let cueEven = (cue.end - cue.start) == 0 && (cue.start - last.end) < gap
                if cue.start - last.end > gap && !cueEven {
                    paragraphs.append(current)
                    current = []
                } else if cue.speaker != nil && cue.speaker != prevSpeaker && !current.isEmpty {
                    paragraphs.append(current)
                    current = []
                }
            }
            current.append(cue)
            prevSpeaker = cue.speaker
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    /// `mm:ss` (or `hh:mm:ss` past an hour) for a timestamp comment.
    static func timestampClock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
    }

    // MARK: - YouTube timedtext XML

    /// Parse `<transcript><text start="0.5" dur="2.3">…</text></transcript>`.
    /// Uses `XMLParser` (entity-decoding built in). `start`/`dur` are seconds.
    /// Some responses wrap in `<timedtext>` instead of `<transcript>`.
    static func parseTimedtextXML(_ data: Data) throws -> [Cue] {
        let delegate = XMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw TimedTextError.parseFailed
        }
        return delegate.cues
    }

    /// `XMLParser` delegate for the YouTube timedtext XML format. Each
    /// `<text>` (or `<text ... kind="asr">`) element carries `start`/`dur` (or
    /// `start`/`end`) and HTML-escaped text.
    private final class XMLDelegate: NSObject, XMLParserDelegate {
        var cues: [Cue] = []
        private var start: TimeInterval = 0
        private var end: TimeInterval = 0
        private var speaker: String?
        private var chars = ""
        private var inText = false

        private static func attribute(_ name: String, in attrs: [String: String]) -> String? {
            if let exact = attrs[name] { return exact }
            return attrs.first { $0.key.hasSuffix(":\(name)") }?.value
        }

        func parser(
            _ parser: XMLParser, didStartElement element: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes attrs: [String: String] = [:]
        ) {
            if element == "text" {
                inText = true
                start = TimeInterval(Self.attribute("start", in: attrs) ?? "0") ?? 0
                let dur = TimeInterval(Self.attribute("dur", in: attrs) ?? "0") ?? 0
                if let endStr = Self.attribute("end", in: attrs) {
                    end = TimeInterval(endStr) ?? 0
                } else {
                    end = start + dur
                }
                speaker = Self.attribute("name", in: attrs)  // YouTube track name
                chars = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { chars += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement element: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            if element == "text" {
                inText = false
                let text = chars.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    // `\n` inside YouTube text separates short newline-stanzas;
                    // normalize to spaces so paragraphing happens upstream.
                    let cleaned = text.replacingOccurrences(of: "\n", with: " ")
                    cues.append(Cue(start: start, end: end, speaker: speaker, text: cleaned))
                }
            }
        }
    }

    // MARK: - YouTube JSON3

    /// Parse `{"events":[{"tStartMs":500,"dDurationMs":2300,"segs":[{"utf8":"Hi "}]}, …]}`.
    struct JSON3Payload: Decodable {
        struct Event: Decodable {
            let tStartMs: Int?
            let dDurationMs: Int?
            let segs: [Segment]?
        }
        struct Segment: Decodable {
            let utf8: String?
        }
        let events: [Event]?
    }

    static func parseJSON3(_ data: Data) throws -> [Cue] {
        let payload = try JSONDecoder().decode(JSON3Payload.self, from: data)
        guard let events = payload.events else { throw TimedTextError.parseFailed }
        var cues: [Cue] = []
        for event in events {
            guard let segs = event.segs else { continue }
            let text = segs.compactMap { $0.utf8 }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = TimeInterval(event.tStartMs ?? 0) / 1000.0
            let duration = TimeInterval(event.dDurationMs ?? 0) / 1000.0
            cues.append(Cue(start: start, end: start + duration, speaker: nil, text: text))
        }
        return cues
    }

    // MARK: - WebVTT

    /// Parse `WEBVTT` files: cue blocks separated by blank lines, each with a
    /// `00:00:00.500 --> 00:00:02.800` timing line (or `mm:ss.mmm`) followed by
    /// one or more text lines.
    static func parseWebVTT(_ data: Data) -> [Cue] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        return parseCueBlocks(text, vtt: true)
    }

    // MARK: - SRT

    /// Parse SRT files: blocks separated by blank lines, each with a numeric
    /// index, a `00:00:00,500 --> 00:00:02,800` timing line, then text lines.
    static func parseSRT(_ data: Data) -> [Cue] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        return parseCueBlocks(text, vtt: false)
    }

    /// Shared block parser for VTT/SRT. Splits on blank lines into cue blocks,
    /// extracts the `-->` timing line and the (optional) index line, and
    /// collects the remaining lines as the cue text. `vtt` controls whether the
    /// first line of each block is an index (SRT) that must be skipped.
    static func parseCueBlocks(_ text: String, vtt: Bool) -> [Cue] {
        // Normalize CRLF/CR → LF once.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Split on blank lines (one or more LF with a blank between blocks).
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0) }
            guard !lines.isEmpty else { continue }
            // Find the timing line (the one containing `-->`).
            guard let timingIdx = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            guard let (start, end) = parseCueTiming(lines[timingIdx]) else { continue }
            // Everything after the timing line is the cue text (skip any VTT
            // cue settings after the `-->` on the same line). The index line
            // (SRT numeric) before the timing line is ignored (it's not text).
            let textLines = lines[(timingIdx + 1)...]
            let body = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            // Strip VTT cue settings (e.g. `align:start position:0%`) that
            // sometimes appear on the timing line's trailing content — already
            // handled because we only read text after it.
            cues.append(Cue(start: start, end: end, speaker: nil, text: cleanupVTT(body)))
        }
        return cues
    }

    /// Remove inline VTT cue tags like `<c>`, `<00:00:01.000>`, `<i>` that
    ///decorate words. Keeps the visible text.
    private static func cleanupVTT(_ body: String) -> String {
        // Strip `<…>` timing/styling tags but keep the text between them.
        var result = ""
        var inTag = false
        for ch in body {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { result.append(ch) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse one `HH:MM:SS.mmm --> HH:MM:SS.mmm` (or `MM:SS.mmm`, or
    /// comma-delimited SRT) line into `(start, end)` seconds. Tolerates
    /// trailing cue settings (VTT) after the end stamp.
    static func parseCueTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        // The end part may carry VTT settings (`00:00:02.800 align:start`); take
        // only the first token (the timestamp) and strip settings.
        let startRaw = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let endToken = parts[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map { String($0) } ?? ""
        guard let start = parseStamp(startRaw), let end = parseStamp(endToken) else {
            return nil
        }
        return (start, end)
    }

    /// Parse `HH:MM:SS.mmm`, `MM:SS.mmm`, or `SS.mmm` into seconds. VTT uses
    /// `.` as the millisecond separator; SRT uses `,`. Both are accepted.
    static func parseStamp(_ raw: String) -> TimeInterval? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        let nums = parts.compactMap { TimeInterval($0) }
        guard nums.count == parts.count, !nums.isEmpty else { return nil }
        // rightmost = seconds + fraction; leftward = minutes, then hours.
        var seconds = 0.0
        for value in nums {
            seconds = seconds * 60 + value
        }
        return seconds
    }
}

/// Errors for the format-agnostic timed-text → markdown pipeline,
/// user-readable so the Add-from-URL sheet can surface them directly.
public enum TimedTextError: Error, LocalizedError, Equatable {
    case parseFailed
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .parseFailed:
            return "The caption file couldn't be parsed."
        case .emptyResponse:
            return "This video has no transcripts."
        }
    }
}

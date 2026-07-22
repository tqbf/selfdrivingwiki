#if PODCAST_TRANSCRIPTS  // Apple Podcasts transcript feature; off for WIKIFS_APP_STORE=1 builds.
import Foundation
// On Linux, `XMLParser` and `XMLParserDelegate` live in the `FoundationXML`
// module (split out from Foundation in Swift CoreLibs). On macOS, Foundation
// re-exports them directly. `canImport` lets us conditionally pull in
// FoundationXML on Linux without affecting the macOS build (#754, #780).
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses Apple's podcast transcript TTML (timed-text XML) into cues and renders
/// plain text — PURE (`XMLParser` over in-memory bytes, no network), so it is
/// unit-tested against a fixture trimmed from a real captured transcript.
///
/// Real Apple TTML nests `<span podcasts:unit="word">` elements inside sentence
/// spans with NO whitespace between them, so a naive character-concatenation
/// yields "WelcometoWarTalk." — the parser must join word units with spaces.
/// Paragraphs (`<p begin end ttm:agent>`) carry timing and the speaker.
///
/// See `plans/podcast-transcripts.md`.
public struct TTMLTranscript: Equatable, Sendable {

    /// One `<p>` paragraph: timing, optional speaker (`ttm:agent`), text.
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

    /// Parse TTML bytes into cues. Throws `PodcastTranscriptError.ttmlParseFailed`
    /// on malformed XML or when no cues can be extracted.
    public static func parse(_ data: Data) throws -> TTMLTranscript {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.cues.isEmpty else {
            throw PodcastTranscriptError.ttmlParseFailed
        }
        return TTMLTranscript(cues: delegate.cues)
    }

    /// The transcript as readable text: one paragraph per cue, prefixed with the
    /// speaker (`SPEAKER_1: …`) when the TTML attributes carry one.
    public var plainText: String {
        cues.map { cue in
            cue.speaker.map { "\($0): \(cue.text)" } ?? cue.text
        }.joined(separator: "\n\n")
    }

    /// A TTML clock value in seconds. Accepts `"SS.mmm"`, `"MM:SS.mmm"`, and
    /// `"HH:MM:SS.mmm"` (the captured file uses both `"0.220"` and
    /// `"1:09:04.480"`). Unparseable / nil → 0.
    static func parseClock(_ raw: String?) -> TimeInterval {
        guard let raw, !raw.isEmpty else { return 0 }
        var seconds: TimeInterval = 0
        for part in raw.split(separator: ":", omittingEmptySubsequences: false) {
            guard let value = TimeInterval(part) else { return 0 }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    // MARK: - XML walking

    /// Streaming `XMLParser` delegate. Namespace processing is OFF, so element
    /// names arrive as written (`p`, `span`) and attributes keep their prefixes
    /// (`ttm:agent`, `podcasts:unit`) — matched by local name so a file with a
    /// different prefix still parses.
    private final class Delegate: NSObject, XMLParserDelegate {
        var cues: [Cue] = []

        // Per-<p> state.
        private var inParagraph = false
        private var begin: TimeInterval = 0
        private var end: TimeInterval = 0
        private var speaker: String?
        /// Word-unit span texts, joined with spaces at `</p>` — the real files
        /// put NO whitespace between word spans.
        private var words: [String] = []
        /// Characters found outside any word span, the fallback for TTML that
        /// carries plain paragraph text instead of word units.
        private var rawText = ""
        private var inWord = false
        private var currentWord = ""

        /// An attribute by its local name, tolerating any namespace prefix.
        private static func attribute(_ name: String, in attrs: [String: String]) -> String? {
            if let exact = attrs[name] { return exact }
            return attrs.first { $0.key.hasSuffix(":\(name)") }?.value
        }

        func parser(
            _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
            qualifiedName: String?, attributes attrs: [String: String] = [:]
        ) {
            switch element {
            case "p":
                inParagraph = true
                begin = parseClock(Self.attribute("begin", in: attrs))
                end = parseClock(Self.attribute("end", in: attrs))
                speaker = Self.attribute("agent", in: attrs)
                words = []
                rawText = ""
            case "span" where inParagraph:
                if Self.attribute("unit", in: attrs) == "word" {
                    inWord = true
                    currentWord = ""
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inParagraph else { return }
            if inWord {
                currentWord += string
            } else {
                rawText += string
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch element {
            case "span" where inWord:
                let word = currentWord.trimmingCharacters(in: .whitespacesAndNewlines)
                if !word.isEmpty { words.append(word) }
                inWord = false
            case "p" where inParagraph:
                let text = words.isEmpty
                    ? rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : words.joined(separator: " ")
                if !text.isEmpty {
                    cues.append(Cue(start: begin, end: end, speaker: speaker, text: text))
                }
                inParagraph = false
            default:
                break
            }
        }
    }
}
#endif

#if PODCAST_TRANSCRIPTS  // Feature off for WIKIFS_APP_STORE=1 builds.
import Foundation
import Testing
@testable import WikiFSCore

/// Tests for `TTMLTranscript` — the pure TTML → cues → text parser. The fixture
/// mirrors the exact structure of the real captured ChinaTalk transcript
/// (`transcript_1000774368453.ttml`): namespaced `<tt>`, `<p>` paragraphs with
/// `begin`/`end`/`ttm:agent`, sentence spans nesting `podcasts:unit="word"` spans
/// with NO whitespace between them — the trap that makes naive text extraction
/// produce "WelcometoWarTalk.".
struct TTMLTranscriptTests {

    /// Trimmed from the real captured file — first words of the episode, real
    /// attribute shapes, two speakers.
    static let fixture = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:podcasts="http://podcasts.apple.com/transcript-ttml-internal" \
        xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en"><head><metadata /></head>\
        <body dur="4148.949"><div begin="0.220" end="1:09:04.480">\
        <p begin="0.220" end="28.620" ttm:agent="SPEAKER_1">\
        <span begin="0.220" end="1.300" podcasts:unit="sentence" xml:lang="en">\
        <span begin="0.220" end="0.500" podcasts:unit="word">Welcome</span>\
        <span begin="0.500" end="0.640" podcasts:unit="word">to</span>\
        <span begin="0.640" end="1.300" podcasts:unit="word">WarTalk.</span></span>\
        <span begin="3.320" end="4.460" podcasts:unit="sentence" xml:lang="en">\
        <span begin="3.320" end="3.540" podcasts:unit="word">With</span>\
        <span begin="3.540" end="3.700" podcasts:unit="word">us</span>\
        <span begin="3.700" end="4.060" podcasts:unit="word">today.</span></span></p>\
        <p begin="30.000" end="35.500" ttm:agent="SPEAKER_2">\
        <span begin="30.000" end="35.500" podcasts:unit="sentence" xml:lang="en">\
        <span begin="30.000" end="31.000" podcasts:unit="word">Thanks</span>\
        <span begin="31.000" end="31.500" podcasts:unit="word">for</span>\
        <span begin="31.500" end="32.000" podcasts:unit="word">having</span>\
        <span begin="32.000" end="32.500" podcasts:unit="word">me.</span></span></p>\
        </div></body></tt>
        """

    @Test func wordSpansJoinWithSpaces() throws {
        let t = try TTMLTranscript.parse(Data(Self.fixture.utf8))
        #expect(t.cues.count == 2)
        #expect(t.cues[0].text == "Welcome to WarTalk. With us today.")
        #expect(t.cues[1].text == "Thanks for having me.")
    }

    @Test func cuesCarryTimingAndSpeaker() throws {
        let t = try TTMLTranscript.parse(Data(Self.fixture.utf8))
        #expect(t.cues[0].start == 0.220)
        #expect(t.cues[0].end == 28.620)
        #expect(t.cues[0].speaker == "SPEAKER_1")
        #expect(t.cues[1].speaker == "SPEAKER_2")
    }

    @Test func plainTextPrefixesSpeakers() throws {
        let t = try TTMLTranscript.parse(Data(Self.fixture.utf8))
        #expect(t.plainText == """
            SPEAKER_1: Welcome to WarTalk. With us today.

            SPEAKER_2: Thanks for having me.
            """)
    }

    @Test func paragraphWithoutWordSpansFallsBackToRawText() throws {
        // Defensive: not every TTML nests word units — plain `<p>` text must survive.
        let xml = """
            <tt xmlns="http://www.w3.org/ns/ttml"><body><div>\
            <p begin="5.0" end="6.0">Hello there.</p>\
            </div></body></tt>
            """
        let t = try TTMLTranscript.parse(Data(xml.utf8))
        #expect(t.cues.count == 1)
        #expect(t.cues[0].text == "Hello there.")
        #expect(t.cues[0].speaker == nil)
    }

    @Test func plainTextOmitsPrefixWhenNoSpeaker() throws {
        let xml = """
            <tt xmlns="http://www.w3.org/ns/ttml"><body><div>\
            <p begin="5.0" end="6.0">Hello there.</p>\
            </div></body></tt>
            """
        let t = try TTMLTranscript.parse(Data(xml.utf8))
        #expect(t.plainText == "Hello there.")
    }

    @Test func malformedXMLThrows() {
        #expect(throws: PodcastTranscriptError.ttmlParseFailed) {
            try TTMLTranscript.parse(Data("<tt><body>".utf8))
        }
    }

    @Test func noCuesThrows() {
        #expect(throws: PodcastTranscriptError.ttmlParseFailed) {
            try TTMLTranscript.parse(Data("<tt><body><div></div></body></tt>".utf8))
        }
    }

    // MARK: - parseClock

    @Test(arguments: [
        ("0.220", 0.220),
        ("28.620", 28.620),
        ("1:09:04.480", 4144.480),   // real `end` value from the captured file
        ("02:15.500", 135.500),
        ("45", 45.0),
    ] as [(String, Double)])
    func clockValuesParse(raw: String, expected: Double) {
        #expect(abs(TTMLTranscript.parseClock(raw) - expected) < 0.0001)
    }

    @Test func unparseableClockIsZero() {
        #expect(TTMLTranscript.parseClock(nil) == 0)
        #expect(TTMLTranscript.parseClock("abc") == 0)
        #expect(TTMLTranscript.parseClock("") == 0)
    }
}
#endif

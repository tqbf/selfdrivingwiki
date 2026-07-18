import Foundation
import Testing
@testable import WikiFSCore

/// Pure unit tests for the format-agnostic timed-text parser (no network).
/// Covers YouTube timedtext XML, YouTube JSON3, WebVTT, SRT, format detection,
/// and the markdown paragraph-grouping + timestamp markers.
struct TimedTextTranscriptTests {

    // MARK: - YouTube timedtext XML

    static let timedtextXML = """
    <?xml version="1.0" encoding="utf-8" ?>
    <transcript>
        <text start="0.5" dur="2.3">Hello &amp; welcome to the talk.</text>
        <text start="2.8" dur="1.5">This is a transcript.</text>
        <text start="4.3" dur="2.0">Let&#39;s begin.</text>
    </transcript>
    """

    @Test func parsesYouTubeTimedtextXML() throws {
        let t = try TimedTextTranscript.parse(Data(Self.timedtextXML.utf8))
        #expect(t.cues.count == 3)
        #expect(t.cues[0].start == 0.5)
        #expect(t.cues[0].end == 2.8)  // 0.5 + 2.3
        #expect(t.cues[1].text == "This is a transcript.")
        // HTML entities decoded by XMLParser.
        #expect(t.cues[0].text == "Hello & welcome to the talk.")
        #expect(t.cues[2].text == "Let's begin.")
    }

    @Test func detectsXMLFormat() throws {
        let fmt = TimedTextTranscript.detectFormat(Data(Self.timedtextXML.utf8))
        #expect(fmt == .timedtextXML)
    }

    @Test func parsesXMLWithEndAttributeInsteadOfDur() throws {
        let xml = """
        <transcript>
            <text start="1.0" end="3.0">First</text>
            <text start="3.5" end="5.5">Second</text>
        </transcript>
        """
        let t = try TimedTextTranscript.parse(Data(xml.utf8))
        #expect(t.cues.count == 2)
        #expect(t.cues[0].end == 3.0)
        #expect(t.cues[1].end == 5.5)
    }

    @Test func emptyXMLCuesThrows() {
        let xml = "<transcript></transcript>"
        #expect(throws: TimedTextError.parseFailed) {
            try TimedTextTranscript.parse(Data(xml.utf8))
        }
    }

    // MARK: - YouTube JSON3

    static let json3 = """
    {"events":[
        {"tStartMs":500,"dDurationMs":2300,"segs":[{"utf8":"Hello "},{"utf8":"world"}]},
        {"tStartMs":2800,"dDurationMs":1500,"segs":[{"utf8":"Second cue"}]}
    ]}
    """

    @Test func parsesJSON3() throws {
        let t = try TimedTextTranscript.parse(Data(Self.json3.utf8))
        #expect(t.cues.count == 2)
        #expect(t.cues[0].start == 0.5)  // ms → s
        #expect(t.cues[0].end == 2.8)    // 0.5 + 2.3
        #expect(t.cues[0].text == "Hello world")
        #expect(t.cues[1].start == 2.8)
        #expect(t.cues[1].text == "Second cue")
    }

    @Test func detectsJSON3Format() throws {
        let fmt = TimedTextTranscript.detectFormat(Data(Self.json3.utf8))
        #expect(fmt == .json3)
    }

    @Test func json3EmptyEventsThrows() {
        let json = "{\"events\":[]}"
        #expect(throws: TimedTextError.parseFailed) {
            try TimedTextTranscript.parse(Data(json.utf8))
        }
    }

    // MARK: - WebVTT

    static let webvtt = """
    WEBVTT

    00:00:00.500 --> 00:00:02.800
    Hello world

    00:00:02.800 --> 00:00:04.300
    This is a transcript

    00:00:04.300 --> 00:00:06.300
    <c.colorE5E5E5>Let's begin</c>
    """

    @Test func parsesWebVTT() throws {
        let t = try TimedTextTranscript.parse(Data(Self.webvtt.utf8))
        #expect(t.cues.count == 3)
        #expect(t.cues[0].start == 0.5)
        #expect(t.cues[0].end == 2.8)
        #expect(t.cues[0].text == "Hello world")
        // Inline VTT tags stripped.
        #expect(t.cues[2].text == "Let's begin")
    }

    @Test func detectsVTTFormat() throws {
        let fmt = TimedTextTranscript.detectFormat(Data(Self.webvtt.utf8))
        #expect(fmt == .webVTT)
    }

    @Test func vttShortTimestampsWork() throws {
        let vtt = """
        WEBVTT

        00:01.500 --> 00:03.800
        Short stamp
        """
        let t = try TimedTextTranscript.parse(Data(vtt.utf8))
        #expect(t.cues.count == 1)
        #expect(t.cues[0].start == 1.5)
        #expect(t.cues[0].end == 3.8)
    }

    @Test func vttWithCueSettingsAfterTimestamp() throws {
        let vtt = """
        WEBVTT

        00:00:00.500 --> 00:00:02.800 align:start position:0%
        Settings after
        """
        let t = try TimedTextTranscript.parse(Data(vtt.utf8))
        #expect(t.cues.count == 1)
        #expect(t.cues[0].end == 2.8)
        #expect(t.cues[0].text == "Settings after")
    }

    // MARK: - SRT

    static let srt = """
    1
    00:00:00,500 --> 00:00:02,800
    Hello world

    2
    00:00:02,800 --> 00:00:04,300
    This is a transcript

    3
    00:00:04,300 --> 00:00:06,300
    Let's begin
    """

    @Test func parsesSRT() throws {
        let t = try TimedTextTranscript.parse(Data(Self.srt.utf8))
        #expect(t.cues.count == 3)
        #expect(t.cues[0].start == 0.5)
        #expect(t.cues[0].end == 2.8)
        #expect(t.cues[0].text == "Hello world")
        #expect(t.cues[2].text == "Let's begin")
    }

    @Test func detectsSRTFormat() throws {
        let fmt = TimedTextTranscript.detectFormat(Data(Self.srt.utf8))
        #expect(fmt == .srt)
    }

    @Test func srtMultiLineText() throws {
        let srt = """
        1
        00:00:00,500 --> 00:00:02,800
        Line one
        Line two
        """
        let t = try TimedTextTranscript.parse(Data(srt.utf8))
        #expect(t.cues.count == 1)
        #expect(t.cues[0].text == "Line one\nLine two")
    }

    @Test func srtShortTimestamps() throws {
        let srt = """
        1
        01:02,000 --> 01:05,000
        One minute two
        """
        let t = try TimedTextTranscript.parse(Data(srt.utf8))
        #expect(t.cues.count == 1)
        #expect(t.cues[0].start == 62.0)
        #expect(t.cues[0].end == 65.0)
    }

    // MARK: - Markdown rendering

    @Test func plainTextGroupsByGap() throws {
        // Cues 0-1 close together (0.5s, 2.8s), cue 2 is 10s later → 2 paragraphs.
        let transcript = TimedTextTranscript(cues: [
            .init(start: 0.5, end: 2.8, speaker: nil, text: "First sentence."),
            .init(start: 2.8, end: 4.0, speaker: nil, text: "Second sentence."),
            .init(start: 14.0, end: 16.0, speaker: nil, text: "After a pause."),
        ])
        let text = transcript.plainText()
        let paragraphs = text.components(separatedBy: "\n\n")
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0] == "First sentence. Second sentence.")
        #expect(paragraphs[1] == "After a pause.")
    }

    @Test func markedTextHasTimestampComments() throws {
        let transcript = TimedTextTranscript(cues: [
            .init(start: 0.5, end: 2.8, speaker: nil, text: "First."),
            .init(start: 65.0, end: 67.0, speaker: nil, text: "One minute in."),
        ])
        let text = transcript.markedText
        // 0.5s rounds to 1 → "00:01"; 65s → "01:05".
        #expect(text.contains("<!-- 00:01 -->"))
        #expect(text.contains("<!-- 01:05 -->"))
    }

    @Test func timestampClockFormats() {
        #expect(TimedTextTranscript.timestampClock(0) == "00:00")
        #expect(TimedTextTranscript.timestampClock(65) == "01:05")
        #expect(TimedTextTranscript.timestampClock(3725) == "1:02:05")
    }

    // MARK: - Stamp parsing

    @Test func parseStampHoursMinutesSeconds() {
        #expect(TimedTextTranscript.parseStamp("01:02:03.500") == 3723.5)
        #expect(TimedTextTranscript.parseStamp("02:03,500") == 123.5)  // SRT comma
        #expect(TimedTextTranscript.parseStamp("03.500") == 3.5)
        #expect(TimedTextTranscript.parseStamp("invalid") == nil)
    }

    @Test func parseCueTiming() throws {
        let (s, e) = try #require(TimedTextTranscript.parseCueTiming(
            "00:00:00.500 --> 00:00:02.800"))
        #expect(s == 0.5)
        #expect(e == 2.8)
    }

    @Test func parseCueTimingWithSettings() throws {
        let (s, e) = try #require(TimedTextTranscript.parseCueTiming(
            "00:00:00.500 --> 00:00:02.800 align:start position:0%"))
        #expect(s == 0.5)
        #expect(e == 2.8)
    }

    // MARK: - Error descriptions

    @Test func errorDescriptionsAreReadable() {
        #expect(TimedTextError.parseFailed.errorDescription == "The caption file couldn't be parsed.")
        #expect(TimedTextError.emptyResponse.errorDescription == "This video has no transcripts.")
    }
}

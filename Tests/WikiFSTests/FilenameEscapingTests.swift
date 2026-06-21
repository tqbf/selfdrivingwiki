import Testing
@testable import WikiFSCore

/// Tests for the deterministic title → filename escaping (INITIAL §5).
struct FilenameEscapingTests {

    @Test func plainTitleIsUnchanged() {
        #expect(FilenameEscaping.escapeTitle("Home") == "Home")
    }

    @Test func collapsesWhitespaceRunsAndTrims() {
        #expect(FilenameEscaping.escapeTitle("  spaced   out  ") == "spaced out")
        #expect(FilenameEscaping.escapeTitle("a\t\tb\nc") == "a b c")
    }

    @Test func replacesSlashAndColonWithDash() {
        #expect(FilenameEscaping.escapeTitle("File Provider / macOS?") == "File Provider - macOS?")
        #expect(FilenameEscaping.escapeTitle("a/b") == "a-b")
        #expect(FilenameEscaping.escapeTitle("12:34") == "12-34")
    }

    @Test func stripsControlCharactersAndNUL() {
        #expect(FilenameEscaping.escapeTitle("a\u{0}b\u{1}c") == "abc")
    }

    @Test func leadingDotGetsUnderscorePrefix() {
        #expect(FilenameEscaping.escapeTitle(".hidden") == "_.hidden")
        #expect(FilenameEscaping.escapeTitle("...x") == "_...x")
    }

    @Test func trimsTrailingSpacesAndPeriods() {
        #expect(FilenameEscaping.escapeTitle("name.") == "name")
        #expect(FilenameEscaping.escapeTitle("name...") == "name")
        // Trailing space collapses in step 1, so test a trailing period after content.
        #expect(FilenameEscaping.escapeTitle("name . ") == "name")
    }

    @Test func emptyBecomesUntitled() {
        #expect(FilenameEscaping.escapeTitle("") == "untitled")
        #expect(FilenameEscaping.escapeTitle("   ") == "untitled")
        #expect(FilenameEscaping.escapeTitle("\u{0}\u{1}") == "untitled")
        // A title that is only a leading dot then trailing-dot-trimmed: "." ->
        // "_." (leading-dot rule fires before trailing trim).
        #expect(FilenameEscaping.escapeTitle(".") == "_")
    }

    @Test func shortIDIsFirstEightChars() {
        #expect(FilenameEscaping.shortID("01KV6EAH410NWC9K9ZM44DNMXT") == "01KV6EAH")
        #expect(FilenameEscaping.shortID("ABC") == "ABC")
    }

    @Test func byTitleFilenameMatchesPlanExamples() {
        #expect(
            FilenameEscaping.byTitleFilename(title: "Home", pageID: "01KV6EAH410NWC9K9ZM44DNMXT")
                == "Home--01KV6EAH.md")
        #expect(
            FilenameEscaping.byTitleFilename(
                title: "File Provider / macOS?", pageID: "01JABCDEFGHJKMNPQRSTVWXYZ0")
                == "File Provider - macOS?--01JABCDE.md")
    }

    @Test func byIDFilenameIsFullULID() {
        #expect(
            FilenameEscaping.byIDFilename(pageID: "01KV6EAH410NWC9K9ZM44DNMXT")
                == "01KV6EAH410NWC9K9ZM44DNMXT.md")
    }

    // MARK: - Ingested files (Phase 5)

    @Test func byIDSourceFilenamePreservesExtension() {
        #expect(
            FilenameEscaping.byIDSourceFilename(
                sourceID: "01KV6EAH410NWC9K9ZM44DNMXT", ext: "pdf")
                == "01KV6EAH410NWC9K9ZM44DNMXT.pdf")
    }

    @Test func byIDSourceFilenameOmitsDotWhenNoExtension() {
        #expect(
            FilenameEscaping.byIDSourceFilename(
                sourceID: "01KV6EAH410NWC9K9ZM44DNMXT", ext: "")
                == "01KV6EAH410NWC9K9ZM44DNMXT")
    }

    @Test func byNameSourceFilenameEscapesStemAddsShortIDPreservesExt() {
        #expect(
            FilenameEscaping.byNameSourceFilename(
                filename: "Trip Report.pdf", ext: "pdf",
                sourceID: "01JABCDEFGHJKMNPQRSTVWXYZ0")
                == "Trip Report--01JABCDE.pdf")
        // Stem with a path-hostile char is escaped; original ext preserved.
        #expect(
            FilenameEscaping.byNameSourceFilename(
                filename: "a/b.txt", ext: "txt", sourceID: "01JABCDEFGHJKMNPQRSTVWXYZ0")
                == "a-b--01JABCDE.txt")
    }

    @Test func byNameSourceFilenameEmptyStemBecomesUntitled() {
        // Extension-less, weird name: stem escapes to "untitled", no dot appended.
        #expect(
            FilenameEscaping.byNameSourceFilename(
                filename: "", ext: "", sourceID: "01JABCDEFGHJKMNPQRSTVWXYZ0")
                == "untitled--01JABCDE")
    }
}

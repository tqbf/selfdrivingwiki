import Foundation
import Testing
import WikiFSTypes

/// Tests for `MimeType` predicates — specifically the `nil`-rejection guards
/// that mutation testing flagged as uncovered (issue #898).
///
/// `isPDF` already had coverage (its `nil` mutant was killed), but `isText`
/// did not: the `guard let mime else { return false }` → `return true` mutant
/// survived because nothing asserted `MimeType.isText(nil) == false`.
struct MimeTypeTests {

    // MARK: - isText

    @Test func isTextReturnsFalseForNil() {
        #expect(MimeType.isText(nil) == false)
    }

    @Test func isTextRecognizesTextTypes() {
        #expect(MimeType.isText("text/plain"))
        #expect(MimeType.isText("text/markdown"))
        #expect(MimeType.isText("text/html"))
        #expect(MimeType.isText("text/mermaid"))
    }

    @Test func isTextIsCaseInsensitive() {
        #expect(MimeType.isText("TEXT/PLAIN"))
        #expect(MimeType.isText("Text/Markdown"))
    }

    @Test func isTextRejectsNonTextTypes() {
        #expect(MimeType.isText("application/pdf") == false)
        #expect(MimeType.isText("image/jpeg") == false)
        #expect(MimeType.isText("application/octet-stream") == false)
    }

    // MARK: - isSourceTextPresentable

    @Test func sourceTextPresentationIncludesXML() {
        #expect(MimeType.isSourceTextPresentable("text/xml"))
        #expect(MimeType.isSourceTextPresentable("application/xml"))
        #expect(MimeType.isSourceTextPresentable("image/svg+xml"))
        #expect(MimeType.isSourceTextPresentable("Application/XML"))
        #expect(MimeType.isSourceTextPresentable("IMAGE/SVG+XML"))
    }

    @Test func sourceTextPresentationIncludesOrdinaryText() {
        #expect(MimeType.isSourceTextPresentable("text/plain"))
        #expect(MimeType.isSourceTextPresentable("text/markdown"))
    }

    @Test func sourceTextPresentationRejectsNonTextContent() {
        #expect(MimeType.isSourceTextPresentable(nil) == false)
        #expect(MimeType.isSourceTextPresentable("application/pdf") == false)
        #expect(MimeType.isSourceTextPresentable("application/json") == false)
        #expect(MimeType.isSourceTextPresentable("image/jpeg") == false)
    }

    // MARK: - isPDF (nil guard — already covered, included for symmetry)

    @Test func isPDFReturnsFalseForNil() {
        #expect(MimeType.isPDF(nil) == false)
    }

    // MARK: - isMarkdown / isMermaid (nil guards)

    @Test func isMarkdownReturnsFalseForNil() {
        #expect(MimeType.isMarkdown(nil) == false)
    }

    @Test func isMermaidReturnsFalseForNil() {
        #expect(MimeType.isMermaid(nil) == false)
    }
}

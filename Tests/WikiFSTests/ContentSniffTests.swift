import Foundation
import Testing
@testable import WikiFSCore

/// Direct tests for the shared `ContentSniff.mimeType(of:)` helper — the
/// canonical magic-number sniffer used by `FormatMaterializer.dispatch` and
/// `addSource` (content-type-over-extension plan).
struct ContentSniffTests {

    @Test func pdfMagicBytes() {
        #expect(ContentSniff.mimeType(of: Data("%PDF-1.4\n".utf8)) == "application/pdf")
        #expect(ContentSniff.mimeType(of: Data("%PDF-1.7".utf8)) == "application/pdf")
    }

    @Test func pngMagicBytes() {
        #expect(ContentSniff.mimeType(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "image/png")
    }

    @Test func jpegMagicBytes() {
        #expect(ContentSniff.mimeType(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
    }

    @Test func gifMagicBytes() {
        #expect(ContentSniff.mimeType(of: Data("GIF89a".utf8)) == "image/gif")
        #expect(ContentSniff.mimeType(of: Data("GIF87a".utf8)) == "image/gif")
    }

    @Test func zipMagicBytes() {
        #expect(ContentSniff.mimeType(of: Data([0x50, 0x4B, 0x03, 0x04])) == "application/zip")
    }

    @Test func inconclusiveBytesReturnNil() {
        #expect(ContentSniff.mimeType(of: Data("<!DOCTYPE html>".utf8)) == nil)
        #expect(ContentSniff.mimeType(of: Data("hello world".utf8)) == nil)
        #expect(ContentSniff.mimeType(of: Data()) == nil)
    }

    @Test func tooShortPrefixDoesNotCrash() {
        // Fewer bytes than the magic patterns — should not crash, just return nil.
        #expect(ContentSniff.mimeType(of: Data([0x89])) == nil)        // PNG needs 4 bytes
        #expect(ContentSniff.mimeType(of: Data([0xFF, 0xD8])) == nil)  // JPEG needs 3
        #expect(ContentSniff.mimeType(of: Data("%PD".utf8)) == nil)    // PDF needs 4+more-checked-later
    }
}

import Foundation
import Testing
@testable import WikiFSCore

/// Tests for `ShareLinkNormalizer` — pure URL-in/URL-out, no network. Covers the
/// Dropbox `www`/bare-host → `dl.dropboxusercontent.com` rewrite (path + query +
/// `.pdf` filename preserved) and the conservative pass-through for everything else.
struct ShareLinkNormalizerTests {

    @Test func dropboxWWWRewritesToDirectDownloadHost() {
        let url = URL(string:
            "https://www.dropbox.com/scl/fi/kvogjh96nkr2z7znclqtr/CPP_behaviorgen.pdf?rlkey=iwznkp0vpbh5ny4v6kopj2bof&e=3&dl=0")!
        let normalized = ShareLinkNormalizer.normalize(url)
        #expect(normalized.host == "dl.dropboxusercontent.com")
        // Path (incl. the .pdf filename) and the full query survive untouched.
        #expect(normalized.path == "/scl/fi/kvogjh96nkr2z7znclqtr/CPP_behaviorgen.pdf")
        #expect(normalized.query == "rlkey=iwznkp0vpbh5ny4v6kopj2bof&e=3&dl=0")
        #expect(normalized.lastPathComponent == "CPP_behaviorgen.pdf")
        #expect(normalized.scheme == "https")
    }

    @Test func dropboxBareHostAlsoRewritten() {
        let url = URL(string: "https://dropbox.com/s/abc/report.pdf?dl=0")!
        let normalized = ShareLinkNormalizer.normalize(url)
        #expect(normalized.absoluteString == "https://dl.dropboxusercontent.com/s/abc/report.pdf?dl=0")
    }

    @Test func nonDropboxURLReturnedUnchanged() {
        let url = URL(string: "https://example.com/files/report.pdf?token=xyz")!
        let normalized = ShareLinkNormalizer.normalize(url)
        // Byte-for-byte identical — we only touch hosts we recognize.
        #expect(normalized.absoluteString == url.absoluteString)
    }

    @Test func alreadyDirectDropboxURLUntouched() {
        // A direct-download Dropbox URL doesn't match the share-host rule, so it
        // passes through unchanged (no double rewrite).
        let url = URL(string: "https://dl.dropboxusercontent.com/scl/fi/x/report.pdf?rlkey=k")!
        #expect(ShareLinkNormalizer.normalize(url).absoluteString == url.absoluteString)
    }

    @Test func dropboxHostMatchIsCaseInsensitive() {
        let url = URL(string: "https://WWW.Dropbox.com/s/abc/report.pdf")!
        #expect(ShareLinkNormalizer.normalize(url).host == "dl.dropboxusercontent.com")
    }
}

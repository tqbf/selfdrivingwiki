import Foundation
import Testing
@testable import WikiFSCore

/// Pure tests for `ZoteroLocalStorage` — an injected `fileExists` predicate means
/// none of these touch the real filesystem.
struct ZoteroLocalStorageTests {

    private let zoteroDir = URL(fileURLWithPath: "/Users/test/Zotero")

    private func attachment(
        key: String = "DJLXA7DG",
        linkMode: String = "imported_file",
        filename: String? = "report.pdf"
    ) -> ZoteroAttachment {
        ZoteroAttachment(
            key: key, parentItem: "PARENT1", linkMode: linkMode,
            filename: filename, contentType: "application/pdf", title: nil)
    }

    @Test func localPathComposesStorageKeyFilename() {
        let path = ZoteroLocalStorage.localPath(zoteroDir: zoteroDir, key: "DJLXA7DG", filename: "report.pdf")
        #expect(path.path == "/Users/test/Zotero/storage/DJLXA7DG/report.pdf")
    }

    @Test func resolveReturnsLocalWhenFileExistsForImportedFile() {
        let result = ZoteroLocalStorage.resolve(
            attachment(linkMode: "imported_file"), zoteroDir: zoteroDir, fileExists: { _ in true })
        #expect(result == .local(zoteroDir.appendingPathComponent("storage/DJLXA7DG/report.pdf")))
    }

    @Test func resolveReturnsLocalWhenFileExistsForImportedURL() {
        let result = ZoteroLocalStorage.resolve(
            attachment(linkMode: "imported_url"), zoteroDir: zoteroDir, fileExists: { _ in true })
        if case .local = result {} else { Issue.record("expected .local, got \(result)") }
    }

    @Test func resolveReturnsUnavailableWhenLocalFileMissing() {
        let result = ZoteroLocalStorage.resolve(
            attachment(), zoteroDir: zoteroDir, fileExists: { _ in false })
        guard case .unavailable = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test func resolveReturnsUnavailableForLinkedFileModeEvenIfPathExists() {
        // No reliable local guarantee for linked_* modes — don't trust a stray
        // file even if `fileExists` would say yes.
        let result = ZoteroLocalStorage.resolve(
            attachment(linkMode: "linked_file"), zoteroDir: zoteroDir, fileExists: { _ in true })
        guard case .unavailable = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test func resolveReturnsUnavailableForLinkedURLMode() {
        let result = ZoteroLocalStorage.resolve(
            attachment(linkMode: "linked_url"), zoteroDir: zoteroDir, fileExists: { _ in true })
        guard case .unavailable = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test func resolveReturnsUnavailableWhenFilenameMissing() {
        let result = ZoteroLocalStorage.resolve(
            attachment(filename: nil), zoteroDir: zoteroDir, fileExists: { _ in true })
        guard case .unavailable = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
    }

    @Test func defaultDirectoryAppendsZoteroToHome() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(ZoteroLocalStorage.defaultDirectory(home: home).path == "/Users/test/Zotero")
    }
}

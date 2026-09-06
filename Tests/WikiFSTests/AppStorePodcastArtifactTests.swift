#if os(macOS)
import Foundation
import Testing

/// AC.12: App Store builds omit the signing helper and carry no
/// private-framework podcast workflow in Swift. The helper TARGET is excluded
/// by Package.swift's reviewed-package filter; this suite pins the remaining
/// invariants as source scans: no Swift production file references the
/// private-framework workflow, and the helper never appears inside the
/// digest-pinned package payloads.
@Suite("App Store podcast artifact", .timeLimit(.minutes(1)))
struct AppStorePodcastArtifactTests {

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        Issue.record("could not locate the repository root")
        throw CocoaError(.fileNoSuchFile)
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            while let candidate = enumerator.nextObject() as? URL {
                if candidate.pathExtension == "swift" { files.append(candidate) }
            }
        }
        return files
    }

    @Test("no private-framework podcast workflow outside the helper target")
    func cleanSourcesContainNoPrivateFrameworkReferences() throws {
        let root = try repositoryRoot()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        // The Obj-C helper target IS the private-framework workflow; it is
        // compiled only outside App Store builds. Every SWIFT file must be
        // free of it. Comments are stripped first (prose may discuss the
        // helper), and the scan looks for PODCAST-private markers only —
        // unrelated dlopen use (JavaScriptCore) is legitimate.
        let forbidden = [
            "PodcastsFoundation",
            "/System/Library/PrivateFrameworks",
        ]
        for file in try swiftFiles(under: sources) {
            // The helper's own directory is excluded by name.
            if file.path.contains("PodcastTokenHelper") { continue }
            var contents = try String(contentsOf: file, encoding: .utf8)
            contents = contents.replacingOccurrences(
                of: #"//.*"#, with: "", options: .regularExpression)
            for needle in forbidden {
                #expect(
                    !contents.contains(needle),
                    "\(file.lastPathComponent) references \(needle); the private-framework workflow must stay inside the excluded helper target")
            }
        }
    }

    @Test("the helper is not part of any reviewed package payload")
    func helperIsAbsentFromPackageDigests() throws {
        let root = try repositoryRoot()
        let packages = root.appendingPathComponent("ExtractorPackages", isDirectory: true)
        let manifests = try FileManager.default.contentsOfDirectory(
            at: packages, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent != "sources.lock.json" }
        #expect(manifests.contains { $0.lastPathComponent == "ApplePodcastTranscript" })
        for package in manifests where package.hasDirectoryPath {
            let manifest = package.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let contents = try String(contentsOf: manifest, encoding: .utf8)
            #expect(
                !contents.contains("podcast-token-helper"),
                "\(package.lastPathComponent) declares the staged helper; operation-local host support is never package payload")
        }
    }

    @Test("the Apple package documents its reviewed-only host-support contract")
    func applePackageProvenanceDocumentsTheHelperBoundary() throws {
        let root = try repositoryRoot()
        let provenance = root
            .appendingPathComponent("ExtractorPackages/ApplePodcastTranscript/PROVENANCE.md")
        let contents = try String(contentsOf: provenance, encoding: .utf8)
        #expect(contents.contains("org.selfdrivingwiki.apple-podcast-transcript"))
        #expect(contents.contains("podcast-token-helper` is NOT part of"))
        #expect(contents.contains("RSS transcript algorithm"))
    }
}
#endif

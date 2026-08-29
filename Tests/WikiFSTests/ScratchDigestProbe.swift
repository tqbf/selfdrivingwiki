import Foundation
import Testing
import WikiFSTypes

struct ScratchDigestProbe {
    @Test func printDoclingCanonicalDigest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExtractorPackages/DoclingServe")
        let manifest = try JSONDecoder().decode(
            ExtractorManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        print("DOClingDIGEST=", try manifest.packageDigest().hex)
        #expect(true)
    }
}

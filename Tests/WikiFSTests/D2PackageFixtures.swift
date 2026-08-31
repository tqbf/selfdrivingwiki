import Foundation

/// Shared constants and repository paths for the D2 renderer-package suites.
/// The identity values mirror `tools/d2/d2-package.lock.json` and the identity
/// block asserted by `scripts/make-d2-renderer-package.sh`; the lock test
/// cross-checks the two.
enum D2PackageFixtures {
    static let packageID = "org.selfdrivingwiki.d2-readonly"
    static let packageVersion = "0.8.2"
    static let upstreamVersion = "0.8.2"
    static let registrationID = "d2"
    static let displayName = "D2"
    static let sourceExtension = "d2"
    static let priority = 100
    static let maximumInputByteCount = 48_000
    static let sourceTarballURL = "https://codeload.github.com/d2lang/d2/tar.gz/refs/tags/v0.8.2"
    static let sourceTarballSHA256 = "9d8b7276c9dd035233008f3a233054ecf5f3c133e89f658f759df6fe3faf6087"
    static let upstreamCommit = "1c0d93ba1abffe0d425d45d5c037d9474807e4f5"
    static let d2WasmSHA256 = "bd11a89bc22d37788d8befabbf0dcbfec640257e69570c600d130a74a4289ac9"
    static let wasmExecSHA256 = "42c92bf26a564050862e648642f9dc529673fb257d8d96139122da317ac46274"

    /// A D2-shaped manifest fixture with the exact declaration set the generator
    /// emits. Digest values are fixed placeholders: decoding tests exercise
    /// structure, not the pinned bytes.
    static let manifestJSON = """
    {
      "revision": 2,
      "packageID": "\(packageID)",
      "version": "\(packageVersion)",
      "descriptors": [
        {
          "reference": {
            "packageID": "\(packageID)",
            "version": "\(packageVersion)",
            "registrationID": "\(registrationID)"
          },
          "displayName": "\(displayName)",
          "implementation": {"webPackage": {"_0": {"path": "index.html"}}},
          "matchers": [{"extensionFallback": {"_0": "\(sourceExtension)"}}],
          "presentations": ["web"],
          "supportedEmbeddingRoles": ["disclosureRow"],
          "approvedAssets": [
            {"path": "index.html", "digest": "aa0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0a"}
          ],
          "capabilities": ["inputRead"],
          "sizeLimits": {"maximumInputByteCount": \(maximumInputByteCount), "maximumDecodedByteCount": \(maximumInputByteCount)},
          "linkPolicy": "none",
          "accessibility": {"supportsVoiceOver": true, "supportsKeyboardNavigation": true},
          "compatibility": {"minimumProtocolRevision": 1, "maximumProtocolRevision": 1},
          "priority": \(priority)
        }
      ],
      "assets": [
        {"path": "index.html", "digest": "aa0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0a"}
      ]
    }
    """

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func toolsDirectory() -> URL {
        repositoryRoot().appending(path: "tools/d2")
    }

    /// The generator's default output. Bare offline `swift test` has no such
    /// folder; `make d2-renderer-package` or the CI generation step creates it.
    static func generatedPackageRoot() -> URL {
        repositoryRoot().appending(path: "tmp/d2-renderer-package/D2")
    }
}

import Foundation
import Testing

/// Guards the manager-neutral runtime resolution contract by scanning
/// extractor-host sources. The scan fails when any of them reintroduces
/// tool-manager knowledge, a runtime directory search, or the retired
/// search-policy machinery (plan step 46). The `ExtractorRuntimeName`
/// documentation comment is part of the contract.
@Suite("Extractor runtime source contract")
struct ExtractorRuntimeSourceContractTests {
    private static let scannedPaths = [
        "Sources/WikiFSCore/Extractor",
        "Sources/WikiFSTypes/Extractor",
        "Sources/WikiFSEngine/ProcessExtractorProvider.swift",
    ]

    /// Tool-manager knowledge must not return to extractor-host sources.
    private static let forbiddenTokens = [
        "MISE_",
        "runtimeSearchPolicy",
        "ExtractorRuntimeSearchPolicy",
        "searchDirectories",
        ".bun/bin",
        ".local/bin",
        ".local/share/mise",
        "mise/shims",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// The runtime-name contract comment that must stay authoritative.
    private static let requiredContractMarkers = [
        "login shell selects the absolute executable",
        "retains that one resolution per prepared",
        "never searches directories and knows no tool manager",
    ]

    private static func locateRepositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw ContractFailure("repository root not found")
    }

    private struct ContractFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func sourceFiles(under root: URL) throws -> [URL] {
        var files: [URL] = []
        for relative in scannedPaths {
            let url = root.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw ContractFailure("missing scanned path: \(relative)")
            }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
                while let candidate = enumerator?.nextObject() as? URL {
                    if candidate.pathExtension == "swift" { files.append(candidate) }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    @Test func forbidsToolManagerAndDirectorySearchLogic() throws {
        let root = try Self.locateRepositoryRoot()
        let files = try Self.sourceFiles(under: root)
        #expect(files.isEmpty == false, "no extractor-host sources found to scan")

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens {
                #expect(
                    contents.contains(token) == false,
                    "\(file.lastPathComponent) reintroduces '\(token)'")
            }
            // The word "mise" (tool manager) must not appear at all in
            // extractor-host sources, with a word boundary so ordinary words
            // cannot false-positive.
            if contents.range(of: #"\bmise\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                Issue.record("\(file.lastPathComponent) mentions a tool manager")
            }
            // Stale immutable-search-list language must not return.
            if contents.range(of: #"immutable search list"#, options: [.regularExpression, .caseInsensitive]) != nil {
                Issue.record("\(file.lastPathComponent) describes the retired immutable search list")
            }
        }
    }

    @Test func runtimeNameDocumentationCarriesTheResolutionContract() throws {
        let root = try Self.locateRepositoryRoot()
        let contractTypes = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/WikiFSTypes/Extractor/ExtractorContractTypes.swift"),
            encoding: .utf8)
        for marker in Self.requiredContractMarkers {
            #expect(
                contractTypes.contains(marker),
                "ExtractorRuntimeName contract comment lost marker: \(marker)")
        }
    }
}

import Foundation
import Testing

/// Guards the extractor-kind-neutrality tenet (AGENTS.md, Modeling rules):
/// extractor-kind POLICY comes from package registration data, never from
/// host branches that privilege one kind. The scan fails when host sources
/// reintroduce a kind comparison or a kind-named policy seam. Typed
/// per-kind extractor APIs and kind-to-value mapping tables are allowed;
/// the distinction is documented in the tenet.
@Suite("Extractor kind-neutrality contract")
struct ExtractorKindNeutralityContractTests {
    private static let scannedRoots = [
        "Sources/WikiFSCore",
        "Sources/WikiFSEngine",
        "Sources/WikiFS",
        "Sources/wikid",
    ]

    private static let requiredTenetMarkers = [
        ("AGENTS.md", "Extractor-kind policy comes from package data"),
        ("docs/architecture/extractor-package-manifest.md", "Kind neutrality"),
    ]

    private struct ContractFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

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

    private static func sourceFiles(under root: URL) throws -> [URL] {
        var files: [URL] = []
        for relative in scannedRoots {
            let url = root.appendingPathComponent(relative)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else {
                throw ContractFailure("missing scanned path: \(relative)")
            }
            while let candidate = enumerator.nextObject() as? URL {
                if candidate.pathExtension == "swift" { files.append(candidate) }
            }
        }
        return files
    }

    /// No policy code compares against an extractor-kind member. A kind
    /// comparison (`== .docx`) is how a host branch privileges one format;
    /// recognition and selection must flow through the registration claims
    /// and route data instead. `.docx` is distinctive enough to scan
    /// textually: the enums carrying it (ExtractorKind, ContentKind) are
    /// exactly the policy surfaces this tenet protects.
    @Test func forbidsExtractorKindComparisons() throws {
        let root = try Self.locateRepositoryRoot()
        let files = try Self.sourceFiles(under: root)
        #expect(files.isEmpty == false, "no host sources found to scan")

        let comparison = try NSRegularExpression(pattern: #"([=!]=)\s*\.docx\b"#)
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..., in: contents)
            let matches = comparison.matches(in: contents, range: range)
            #expect(
                matches.isEmpty,
                "\(file.lastPathComponent) compares against the .docx extractor kind; policy must come from registration data")
        }
    }

    /// No policy seam is NAMED after a kind. `docxImportExtractor` and
    /// `autoExtractDocxIfRegistered` were this smell: the seam shape itself
    /// hard-coded one format, so every future kind needed a new property and
    /// gate. Seams are kind-neutral (`importExtractorProvider`); typed
    /// per-kind extractor protocols and their `prepare…` functions keep
    /// their kind names because their operation shapes genuinely differ.
    @Test func forbidsKindNamedPolicySeams() throws {
        let root = try Self.locateRepositoryRoot()
        let files = try Self.sourceFiles(under: root)
        let patterns = [
            // kind-first: docxImport…, pdfAutoExtraction…
            #"(?i)\b(docx|pdf|html)[a-z]*(import|auto)"#,
            // kind-last: autoExtractDocx…, runDocxImport…
            #"(?i)\b[a-z]*(import|auto)[a-z]*(docx|pdf|html)\b"#,
        ]
        let regexes = try patterns.map {
            try NSRegularExpression(pattern: $0)
        }
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            // Identifiers only: strip comments first so prose cannot trip
            // the scan.
            let stripped = contents
                .replacingOccurrences(
                    of: #"//.*"#,
                    with: "",
                    options: .regularExpression)
            for regex in regexes {
                let range = NSRange(stripped.startIndex..., in: stripped)
                let matches = regex.matches(in: stripped, range: range)
                #expect(
                    matches.isEmpty,
                    "\(file.lastPathComponent) names a policy seam after an extractor kind; seams are kind-neutral")
            }
        }
    }

    /// The tenet itself must stay documented where contributors look:
    /// AGENTS.md's modeling rules and the normative extractor architecture
    /// document.
    @Test func tenetIsDocumented() throws {
        let root = try Self.locateRepositoryRoot()
        for (path, marker) in Self.requiredTenetMarkers {
            let contents = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8)
            #expect(
                contents.contains(marker),
                "\(path) lost the extractor-kind-neutrality tenet marker")
        }
    }
}

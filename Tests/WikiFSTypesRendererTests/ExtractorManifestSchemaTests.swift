import Foundation
import Testing
import WikiFSTypes

struct ExtractorManifestSchemaTests {
    @Test func validCorpusDecodesAndInvalidCorpusIsRejected() throws {
        let root = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/ExtractorManifests"))
        let valid = try jsonFiles(below: root.appendingPathComponent("valid"))
        let invalid = try jsonFiles(below: root.appendingPathComponent("invalid"))
        #expect(valid.isEmpty == false)
        #expect(invalid.isEmpty == false)
        for url in valid {
            _ = try JSONDecoder().decode(ExtractorManifest.self, from: Data(contentsOf: url))
        }
        for url in invalid {
            #expect(throws: Error.self, Comment(rawValue: url.lastPathComponent)) {
                _ = try JSONDecoder().decode(ExtractorManifest.self, from: Data(contentsOf: url))
            }
        }
    }

    @Test func schemaEnumsAndLimitsMatchSwiftPolicy() throws {
        let root = repositoryRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("Schemas/extractor-package-manifest-v1.schema.json"))
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let capabilities = try #require(properties["capabilities"] as? [String: Any])
        let capabilityItems = try #require(capabilities["items"] as? [String: Any])
        let capabilityValues = try #require(capabilityItems["enum"] as? [String])
        #expect(Set(capabilityValues) == Set(ExtractorCapability.allCases.map(\.rawValue)))

        let registrations = try #require(properties["registrations"] as? [String: Any])
        let registrationItems = try #require(registrations["items"] as? [String: Any])
        let registrationProperties = try #require(registrationItems["properties"] as? [String: Any])
        let kinds = try #require(registrationProperties["kinds"] as? [String: Any])
        let kindItems = try #require(kinds["items"] as? [String: Any])
        #expect(Set(try #require(kindItems["enum"] as? [String])) == Set(ExtractorKind.allCases.map(\.rawValue)))

        let limits = try #require(properties["limits"] as? [String: Any])
        let limitProperties = try #require(limits["properties"] as? [String: Any])
        #expect(maximum("maximumInputByteCount", in: limitProperties) == ExtractorHostLimits.maximumInputByteCount)
        #expect(maximum("maximumMarkdownOutputByteCount", in: limitProperties) == ExtractorHostLimits.maximumMarkdownOutputByteCount)
        #expect(maximum("maximumDurationMilliseconds", in: limitProperties) == ExtractorHostLimits.maximumDurationMilliseconds)
        #expect(maximum("maximumProgressEventCount", in: limitProperties) == ExtractorHostLimits.maximumProgressEventCount)
    }

    private func maximum(_ name: String, in properties: [String: Any]) -> Int? {
        (properties[name] as? [String: Any])?["maximum"] as? Int
    }

    private func jsonFiles(below directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

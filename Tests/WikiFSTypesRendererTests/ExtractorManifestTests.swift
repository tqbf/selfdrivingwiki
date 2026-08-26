import Foundation
import Testing
import WikiFSTypes

struct ExtractorManifestTests {
    @Test func canonicalDigestIsStableAcrossInputOrder() throws {
        let first = try manifest(registrations: [registration("html"), registration("pdf")], reverseFiles: false)
        let second = try manifest(registrations: [registration("pdf"), registration("html")], reverseFiles: true)
        #expect(first == second)
        #expect(try first.canonicalJSON() == second.canonicalJSON())
        #expect(try first.packageDigest() == second.packageDigest())
    }

    @Test func modelDownloadRequiresNetwork() throws {
        #expect(throws: ExtractorValidationError.capabilityRequiresNetwork(.modelDownload)) {
            _ = try manifest(capabilities: [.modelDownload])
        }
        _ = try manifest(capabilities: [.network, .modelDownload])
    }

    @Test func duplicateRegistrationsAndPathsAreRejected() throws {
        let duplicate = try registration("pdf")
        #expect(throws: ExtractorValidationError.duplicateRegistration(duplicate.id)) {
            _ = try manifest(registrations: [duplicate, duplicate])
        }
        let entry = try file("bin/extractor", byte: 1)
        #expect(throws: ExtractorValidationError.duplicatePath(entry.path)) {
            _ = try manifest(files: [entry, entry])
        }
    }

    @Test func normalizedPathCollisionsAreRejected() throws {
        let first = try file("Assets/Café.js", byte: 1)
        let second = try file("assets/Cafe\u{301}.js", byte: 2)
        #expect(throws: ExtractorValidationError.normalizedPathCollision(second.path)) {
            _ = try manifest(files: [try file("bin/extractor", byte: 3), first, second])
        }
    }

    @Test func duplicateSetValuesAreRejectedDuringDecode() throws {
        let fixture = try manifest()
        let encoded = try JSONEncoder().encode(fixture)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        var duplicateCapabilities = object
        duplicateCapabilities["capabilities"] = ["network", "network"]
        let capabilityData = try JSONSerialization.data(withJSONObject: duplicateCapabilities)
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(ExtractorManifest.self, from: capabilityData)
        }

        var duplicateKinds = object
        var registrations = try #require(duplicateKinds["registrations"] as? [[String: Any]])
        registrations[0]["kinds"] = ["pdf", "pdf"]
        duplicateKinds["registrations"] = registrations
        let registrationData = try JSONSerialization.data(withJSONObject: duplicateKinds)
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(ExtractorManifest.self, from: registrationData)
        }
    }

    @Test func entryPointMustBeDeclaredAndLimitsStayWithinPolicy() throws {
        #expect(throws: ExtractorValidationError.invalidManifest("entry point is not declared")) {
            _ = try manifest(files: [file("other", byte: 1)])
        }
        #expect(throws: ExtractorValidationError.limitExceedsHostPolicy("duration")) {
            _ = try ExtractorOperationLimits(
                maximumInputByteCount: 1,
                maximumMarkdownOutputByteCount: 1,
                maximumDurationMilliseconds: ExtractorHostLimits.maximumDurationMilliseconds + 1,
                maximumProgressEventCount: 1)
        }
    }

    @Test func runtimeLaunchRoundTripsAndDirectRejectsRuntimeFields() throws {
        let command = try ExtractorRuntimeName(validating: "bun")
        let launch = ExtractorLaunch.runtime(command: command, arguments: ["--smol"])
        let encoded = try JSONEncoder().encode(launch)
        #expect(try JSONDecoder().decode(ExtractorLaunch.self, from: encoded) == launch)
        let invalid = Data(#"{"mode":"direct","command":"bun"}"#.utf8)
        #expect(throws: Error.self) { _ = try JSONDecoder().decode(ExtractorLaunch.self, from: invalid) }
    }

    private func manifest(
        registrations: [ExtractorRegistration]? = nil,
        capabilities: Set<ExtractorCapability> = [],
        files: [ExtractorPackageFile]? = nil,
        reverseFiles: Bool = false
    ) throws -> ExtractorManifest {
        var declaredFiles = try files ?? [file("bin/extractor", byte: 1), file("lib/module.js", byte: 2)]
        if reverseFiles { declaredFiles.reverse() }
        return try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.extractor"),
            version: ExtractorPackageVersion(validating: "1.2.3"),
            displayName: "Example Extractor",
            protocolRevision: .v1,
            entryPoint: ExtractorRelativePath(validating: "bin/extractor"),
            launch: .direct,
            registrations: registrations ?? [registration("pdf")],
            capabilities: capabilities,
            files: declaredFiles,
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 2_048,
                maximumDurationMilliseconds: 30_000,
                maximumProgressEventCount: 20))
    }

    private func registration(_ rawID: String) throws -> ExtractorRegistration {
        try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: rawID),
            displayName: rawID.uppercased(),
            kinds: rawID == "html" ? [.html] : [.pdf],
            mimeTypes: [ExtractorMIMEType(validating: rawID == "html" ? "text/html" : "application/pdf")],
            filenameExtensions: [ExtractorFileExtension(validating: rawID == "html" ? "html" : "pdf")])
    }

    private func file(_ path: String, byte: UInt8) throws -> ExtractorPackageFile {
        ExtractorPackageFile(
            path: try ExtractorRelativePath(validating: path),
            digest: try ExtractorPackageDigest(bytes: Array(repeating: byte, count: 32)))
    }
}

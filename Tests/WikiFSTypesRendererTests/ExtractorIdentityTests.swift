import Foundation
import Testing
import WikiFSTypes

struct ExtractorIdentityTests {
    @Test func validatesPackageAndRuntimeBoundaries() throws {
        #expect(ExtractorPackageID(rawValue: "Org.example.x") == nil)
        #expect(ExtractorPackageID(rawValue: "org.example.x") != nil)
        #expect(ExtractorRuntimeName(rawValue: "runtime/name") == nil)
        #expect(ExtractorRuntimeName(rawValue: "pdf-runtime") != nil)
        #expect(ExtractorMIMEType(rawValue: "Text/HTML") == nil)
        #expect(ExtractorFileExtension(rawValue: ".pdf") == nil)
        #expect(ExtractorRelativePath(rawValue: "../secret") == nil)
        #expect(ExtractorRelativePath(rawValue: "/absolute") == nil)
        #expect(ExtractorRelativePath(rawValue: "bin/tool") != nil)
    }

    @Test func strictSemVerAndSemanticOrdering() throws {
        let a = try ExtractorPackageVersion(validating: "1.0.0-alpha.1")
        let b = try ExtractorPackageVersion(validating: "1.0.0")
        #expect(a < b)
        #expect(ExtractorPackageVersion(rawValue: "01.0.0") == nil)
        #expect(ExtractorPackageVersion(rawValue: "1.0") == nil)
        #expect(ExtractorPackageVersion(rawValue: "1.0.0-01") == nil)
        #expect(ExtractorPackageVersion(rawValue: "1.0.0+build.1") != nil)
    }

    @Test func digestIsLowercaseFixedWidthAndHashes() throws {
        #expect(throws: ExtractorValidationError.self) { try ExtractorPackageDigest(hex: String(repeating: "a", count: 63)) }
        #expect(throws: ExtractorValidationError.self) { try ExtractorPackageDigest(hex: String(repeating: "A", count: 64)) }
        let digest = ExtractorSHA256.digest(Data("abc".utf8))
        #expect(digest.bytes.count == 32)
        #expect(digest.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func UUIDAndClosedContractTypes() throws {
        let run = ExtractorPackagePluginRunID()
        let request = ExtractorRequestID()
        #expect(run.rawValue != UUID())
        #expect(try ExtractorPackagePluginRunID(validating: run.rawValue.uuidString) == run)
        #expect(try ExtractorRequestID(validating: request.rawValue.uuidString) == request)
        #expect(ExtractorProtocolRevision(rawValue: 1) != nil)
        // Revision 2 (issue #1159) is a supported protocol revision; 3 is not.
        #expect(ExtractorProtocolRevision(rawValue: 2) != nil)
        #expect(ExtractorProtocolRevision(rawValue: 3) == nil)
        #expect(ExtractorKind.allCases == [.pdf, .html])
        #expect(ExtractorFailureCause.allCases.count == 10)
    }

    @Test func codableRevalidatesStringBoundaries() throws {
        let decoder = JSONDecoder()
        #expect(throws: Error.self) {
            _ = try decoder.decode(ExtractorRegistrationID.self, from: Data(#""Bad_ID""#.utf8))
        }
        #expect(throws: Error.self) {
            _ = try decoder.decode(ExtractorRelativePath.self, from: Data(#""../secret""#.utf8))
        }
        let request = ExtractorRequestID()
        let encoded = try JSONEncoder().encode(request)
        #expect(try decoder.decode(ExtractorRequestID.self, from: encoded) == request)
    }

    @Test func referencesKeepExtractorNamespace() throws {
        let package = try ExtractorPackageID(validating: "org.example.extractor")
        let version = try ExtractorPackageVersion(validating: "1.2.3")
        let registration = try ExtractorRegistrationID(validating: "main")
        let digest = try ExtractorPackageDigest(bytes: Array(repeating: 0, count: 32))
        let revision = ExtractorPackageRevisionID(packageID: package, version: version, digest: digest)
        let exact = ExtractorReference(revision: revision, registrationID: registration)
        let logical = LogicalExtractorReference(packageID: package, registrationID: registration)
        #expect(exact.revision.packageID == logical.packageID)
        #expect(exact.registrationID == logical.registrationID)
    }
}

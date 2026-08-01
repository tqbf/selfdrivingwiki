import Foundation
import Testing
import WikiFSTypes

struct RendererSHA256Tests {
    @Test func testDigestBytes() throws {
        let digest = RendererSHA256.digest(Data("abc".utf8))
        #expect(digest.bytes == [
            0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA,
            0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23,
            0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C,
            0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD,
        ])
    }
}

struct RendererDigestHexCodecTests {
    @Test func testCanonicalLowercaseHex() throws {
        let digest = try RendererSHA256Digest(hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(digest.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func testRejectsMalformedDigests() {
        #expect(throws: RendererDigestError.self) {
            _ = try RendererSHA256Digest(hex: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        }
        #expect(throws: RendererDigestError.self) {
            _ = try RendererSHA256Digest(hex: "1234")
        }
        #expect(throws: RendererDigestError.self) {
            _ = try RendererSHA256Digest(hex: String(repeating: "g", count: 64))
        }
    }
}

struct RendererPortableHashImportTests {
    @Test func testSupportedPlatformImports() {
        #if os(macOS) || os(Linux)
        let digest = RendererSHA256.digest(Data())
        #expect(digest.bytes.count == RendererSHA256Digest.byteCount)
        #else
        Issue.record("WikiFSTypes must compile only on declared supported platforms")
        #endif
    }
}

struct RendererReferenceShapeTests {
    @Test func exactAndLogicalReferencesShareOnlyPackageAndRegistrationIdentity() throws {
        let packageID = try RendererPackageID(validating: "org.example.viewer")
        let version = try RendererPackageVersion(validating: "1.2.3")
        let registrationID = try RendererRegistrationID(validating: "viewer")
        let exact = RendererReference(packageID: packageID, version: version, registrationID: registrationID)
        let logical = LogicalRendererReference(packageID: packageID, registrationID: registrationID)
        #expect(exact.packageID == logical.packageID)
        #expect(exact.registrationID == logical.registrationID)
    }
}

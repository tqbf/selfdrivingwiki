import ExtractorPackageToolCore
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Extractor package tool core", .serialized, .timeLimit(.minutes(1)))
struct ExtractorPackageToolCoreTests {
    @Test func validateReturnsStableRevisionAndCleansInvocationRoot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let output = try fixture.executor().execute(
            arguments: ["validate", fixture.packageRoot.path])

        #expect(output.command == "validate")
        let expectedDigest = try fixture.manifest.packageDigest().hex
        #expect(output.packageID == fixture.manifest.packageID.rawValue)
        #expect(output.version == fixture.manifest.version.rawValue)
        #expect(output.packageDigest == expectedDigest)
        #expect(output.registrationIDs == ["pdf"])
        #expect(output.protocolRevision == 1)
        #expect(output.frameCount == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.executionMarker.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.invocationRoot.path) == false)
    }

    @Test func protocolSmokeValidatesRequestFramesAndTerminal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let requestID = ExtractorRequestID()
        let outputPath = try ExtractorRelativePath(validating: "output/result.md")
        let request = try ExtractorProtocolRequest(
            requestID: requestID,
            protocolRevision: .v1,
            kind: .pdf,
            mimeType: ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "source.pdf",
            inputPath: ExtractorRelativePath(validating: "input/source.pdf"),
            outputPath: outputPath,
            deadlineMillisecondsSince1970: 1_900_000_000_000)
        try JSONEncoder().encode(request).write(to: fixture.requestURL)
        let frames: [ExtractorProtocolFrame] = [
            .progress(try ExtractorProgressFrame(
                requestID: requestID,
                completedUnitCount: 1,
                totalUnitCount: 1,
                message: "complete")),
            .result(try ExtractorResultFrame(
                requestID: requestID,
                outputPath: outputPath,
                markdownByteCount: 12)),
        ]
        try encodedLines(frames).write(to: fixture.framesURL)

        let output = try fixture.executor().execute(arguments: [
            "protocol-smoke",
            fixture.packageRoot.path,
            fixture.requestURL.path,
            fixture.framesURL.path,
        ])

        #expect(output.command == "protocol-smoke")
        #expect(output.frameCount == 2)
        #expect(output.progressEventCount == 1)
        #expect(output.terminalKind == "result")
        #expect(FileManager.default.fileExists(atPath: fixture.executionMarker.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.invocationRoot.path) == false)
    }

    @Test func invalidCommandsAndProtocolFixturesFailWithTypedErrors() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(throws: ExtractorPackageToolFailure.invalidArguments) {
            _ = try fixture.executor().execute(arguments: [])
        }

        let request = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(),
            protocolRevision: .v1,
            kind: .html,
            mimeType: ExtractorMIMEType(validating: "text/html"),
            originalFilename: "source.html",
            inputPath: ExtractorRelativePath(validating: "input/source.html"),
            outputPath: ExtractorRelativePath(validating: "output/result.md"),
            deadlineMillisecondsSince1970: 1_900_000_000_000)
        try JSONEncoder().encode(request).write(to: fixture.requestURL)
        try Data("{}\n".utf8).write(to: fixture.framesURL)

        #expect(throws: ExtractorPackageToolFailure.unsupportedRegistration) {
            _ = try fixture.executor().execute(arguments: [
                "protocol-smoke",
                fixture.packageRoot.path,
                fixture.requestURL.path,
                fixture.framesURL.path,
            ])
        }
        #expect(FileManager.default.fileExists(atPath: fixture.invocationRoot.path) == false)
    }

    @Test(
        "protocol smoke rejects malformed and mismatched frames",
        arguments: ProtocolFailureCase.allCases)
    func protocolSmokeRejectsMalformedAndMismatchedFrames(testCase: ProtocolFailureCase) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let requestID = ExtractorRequestID()
        let outputPath = try ExtractorRelativePath(validating: "output/result.md")
        let request = try ExtractorProtocolRequest(
            requestID: requestID,
            protocolRevision: .v1,
            kind: .pdf,
            mimeType: ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "source.pdf",
            inputPath: ExtractorRelativePath(validating: "input/source.pdf"),
            outputPath: outputPath,
            deadlineMillisecondsSince1970: 1_900_000_000_000)
        try JSONEncoder().encode(request).write(to: fixture.requestURL)
        try testCase.frameData(requestID: requestID, outputPath: outputPath).write(to: fixture.framesURL)

        #expect(throws: testCase.expectedFailure) {
            _ = try fixture.executor().execute(arguments: [
                "protocol-smoke",
                fixture.packageRoot.path,
                fixture.requestURL.path,
                fixture.framesURL.path,
            ])
        }
        #expect(FileManager.default.fileExists(atPath: fixture.invocationRoot.path) == false)
    }

    @Test func protocolFixtureSymlinksAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.testRoot.appendingPathComponent("target-request.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.requestURL, withDestinationURL: target)
        try Data("{}\n".utf8).write(to: fixture.framesURL)

        #expect(throws: ExtractorPackageToolFailure.fileSystem) {
            _ = try fixture.executor().execute(arguments: [
                "protocol-smoke",
                fixture.packageRoot.path,
                fixture.requestURL.path,
                fixture.framesURL.path,
            ])
        }
    }

    @Test func sequenceFailureAndCleanupFailureRemainTyped() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let requestID = ExtractorRequestID()
        let outputPath = try ExtractorRelativePath(validating: "output/result.md")
        let request = try ExtractorProtocolRequest(
            requestID: requestID,
            protocolRevision: .v1,
            kind: .pdf,
            mimeType: ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "source.pdf",
            inputPath: ExtractorRelativePath(validating: "input/source.pdf"),
            outputPath: outputPath,
            deadlineMillisecondsSince1970: 1_900_000_000_000)
        try JSONEncoder().encode(request).write(to: fixture.requestURL)
        try encodedLines([.progress(try ExtractorProgressFrame(
            requestID: requestID,
            message: "still running"))]).write(to: fixture.framesURL)

        #expect(throws: ExtractorPackageToolFailure.sequence(.missingTerminal)) {
            _ = try fixture.executor().execute(arguments: [
                "protocol-smoke",
                fixture.packageRoot.path,
                fixture.requestURL.path,
                fixture.framesURL.path,
            ])
        }

        let cleanupFailure = ExtractorPackageToolExecutor(
            validationRootFactory: { fixture.invocationRoot },
            rootCleanup: { _ in throw CocoaError(.fileWriteUnknown) })
        #expect(throws: ExtractorPackageToolFailure.cleanupFailed) {
            _ = try cleanupFailure.execute(arguments: ["validate", fixture.packageRoot.path])
        }
    }

    private func encodedLines(_ frames: [ExtractorProtocolFrame]) throws -> Data {
        var data = Data()
        let encoder = JSONEncoder()
        for frame in frames {
            data.append(try encoder.encode(frame))
            data.append(0x0A)
        }
        return data
    }
}

enum ProtocolFailureCase: CaseIterable, CustomStringConvertible {
    case malformedJSON
    case requestMismatch
    case outputPathMismatch

    var description: String {
        switch self {
        case .malformedJSON: "malformed JSON"
        case .requestMismatch: "request mismatch"
        case .outputPathMismatch: "output path mismatch"
        }
    }

    var expectedFailure: ExtractorPackageToolFailure {
        switch self {
        case .malformedJSON: .frames(.malformedJSON)
        case .requestMismatch: .sequence(.requestMismatch)
        case .outputPathMismatch: .sequence(.outputPathMismatch)
        }
    }

    func frameData(
        requestID: ExtractorRequestID,
        outputPath: ExtractorRelativePath
    ) throws -> Data {
        switch self {
        case .malformedJSON:
            return Data("not-json\n".utf8)
        case .requestMismatch:
            return try encodeLines([.failure(ExtractorFailureFrame(
                requestID: ExtractorRequestID(),
                cause: .extractionFailure,
                message: "failed"))])
        case .outputPathMismatch:
            return try encodeLines([.result(ExtractorResultFrame(
                requestID: requestID,
                outputPath: ExtractorRelativePath(validating: "output/other.md"),
                markdownByteCount: 1))])
        }
    }

    private func encodeLines(_ frames: [ExtractorProtocolFrame]) throws -> Data {
        var data = Data()
        for frame in frames {
            data.append(try JSONEncoder().encode(frame))
            data.append(0x0A)
        }
        return data
    }
}

private final class Fixture: @unchecked Sendable {
    let testRoot: URL
    let packageRoot: URL
    let invocationRoot: URL
    let requestURL: URL
    let framesURL: URL
    let executionMarker: URL
    let manifest: ExtractorManifest

    init() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-package-tool-tests-\(UUID().uuidString)", isDirectory: true)
        packageRoot = testRoot.appendingPathComponent("package", isDirectory: true)
        invocationRoot = testRoot.appendingPathComponent("invocation", isDirectory: true)
        requestURL = testRoot.appendingPathComponent("request.json")
        framesURL = testRoot.appendingPathComponent("frames.jsonl")
        executionMarker = testRoot.appendingPathComponent("executed")
        let entry = packageRoot.appendingPathComponent("bin/extractor")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("#!/bin/sh\ntouch \"\(executionMarker.path)\"\n".utf8)
        try bytes.write(to: entry)
        guard chmod(entry.path, 0o700) == 0 else { throw POSIXError(.EIO) }
        let entryPath = try ExtractorRelativePath(validating: "bin/extractor")
        manifest = try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.tool"),
            version: ExtractorPackageVersion(validating: "1.2.3"),
            displayName: "Tool Fixture",
            protocolRevision: .v1,
            entryPoint: entryPath,
            launch: .direct,
            registrations: [ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "pdf"),
                displayName: "PDF",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")])],
            capabilities: [],
            files: [ExtractorPackageFile(
                path: entryPath,
                digest: ExtractorSHA256.digest(bytes))],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 2_048,
                maximumDurationMilliseconds: 30_000,
                maximumProgressEventCount: 4))
        try JSONEncoder().encode(manifest).write(to: packageRoot.appendingPathComponent("manifest.json"))
    }

    func executor() -> ExtractorPackageToolExecutor {
        ExtractorPackageToolExecutor(validationRootFactory: { self.invocationRoot })
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: testRoot.path) else { return }
        do { try FileManager.default.removeItem(at: testRoot) }
        catch { Issue.record("Extractor package tool fixture cleanup failed: \(error)") }
    }
}

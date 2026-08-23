#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore
import WikiFSTypes

@Suite("JSON Canvas native attachment hosted validation", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct JSONCanvasAttachmentHostedTests {
    @Test("source and fenced native attachments mount and preserve their authorization forms")
    func sourceAndFencedAttachmentsMountWithExactAuthorization() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }

        let source = try Self.source(bytes: Self.canvas)
        let pin = try NativeJSONCanvasAttachmentInput.SourcePin(validating: source)
        let fence = try Self.fence(bytes: Self.canvas)
        var resolvedPins: [NativeJSONCanvasAttachmentInput.SourcePin] = []
        let factory = NativeJSONCanvasAttachmentFactory { requestedPin in
            resolvedPins.append(requestedPin)
            return Self.canvas
        }
        let sourceHost = Self.host(try factory.makeView(for: .source(pin)))
        let fencedHost = Self.host(try factory.makeView(for: .fenced(fence)))
        defer {
            Self.release(sourceHost)
            Self.release(fencedHost)
        }

        let expectedHostBounds = CGRect(origin: .zero, size: Self.hostedCanvasSize)
        try await Self.waitFor(description: "source JSON Canvas host layout") {
            sourceHost.view.bounds == expectedHostBounds
        }
        try await Self.waitFor(description: "fenced JSON Canvas host layout") {
            fencedHost.view.bounds == expectedHostBounds
        }
        try #require(sourceHost.view.bounds == expectedHostBounds)
        try #require(fencedHost.view.bounds == expectedHostBounds)
        #expect(resolvedPins == [pin])

        let badSourceFactory = NativeJSONCanvasAttachmentFactory { _ in Data("bad".utf8) }
        do {
            _ = try badSourceFactory.makeView(for: .source(pin))
            Issue.record("expected source fallback to preserve a source failure")
        } catch let failure as NativeJSONCanvasAttachmentFailure {
            #expect(failure == .source(input: pin, reason: .digestMismatch))
        }
        let oversizedFence = try Self.fence(
            bytes: Data(repeating: 0, count: JSONCanvasLimits.maximumInputByteCount + 1))
        do {
            _ = try factory.makeView(for: .fenced(oversizedFence))
            Issue.record("expected fenced fallback to preserve a fenced failure")
        } catch let failure as NativeJSONCanvasAttachmentFailure {
            #expect(failure == .fenced(input: oversizedFence, reason: .oversizedInput))
        }
    }

    @Test("hosted source and fenced validation creates no version or provenance activity")
    func hostedValidationDoesNotPersist() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }

        let store = try TestStoreFactory.inMemory()
        let storedSource = try store.addSource(
            filename: "hosted.canvas",
            data: Self.canvas,
            mimeType: BuiltInRendererMIME.json)
        let storedVersion = try #require(try store.activeContentVersion(sourceID: storedSource.id))
        let source = try RendererEmbeddedContent.Source(
            sourceID: storedSource.id,
            sourceVersionID: storedVersion.id,
            mimeType: try RendererMIMEType(validating: BuiltInRendererMIME.json),
            bytes: Self.canvas)
        let sourcePin = try NativeJSONCanvasAttachmentInput.SourcePin(validating: source)
        let page = try store.createPage(
            title: "Hosted Canvas",
            body: "Canvas attachment",
            provenance: [.init(sourceID: storedSource.id, role: .primary)])
        let pageVersionID = try #require(try store.pageHeadVersionID(pageID: page.id))
        let fenced = try Self.fence(
            bytes: Self.canvas,
            pageID: page.id,
            pageVersionID: pageVersionID)
        let before = try Self.persistenceObservation(
            store: store,
            sourceID: storedSource.id,
            pageID: page.id,
            pageVersionID: pageVersionID)

        var resolvedPins: [NativeJSONCanvasAttachmentInput.SourcePin] = []
        let factory = NativeJSONCanvasAttachmentFactory { requestedPin in
            resolvedPins.append(requestedPin)
            guard requestedPin == sourcePin else { throw HostedJSONCanvasAttachmentError.unexpectedSourcePin }
            return try store.sourceContent(versionID: storedVersion.id)
        }
        let sourceHost = Self.host(try factory.makeView(
            for: NativeJSONCanvasAttachmentInput.source(sourcePin)))
        let fencedHost = Self.host(try factory.makeView(
            for: NativeJSONCanvasAttachmentInput.fenced(fenced)))
        defer {
            Self.release(sourceHost)
            Self.release(fencedHost)
        }

        let expectedHostBounds = CGRect(origin: .zero, size: Self.hostedCanvasSize)
        try await Self.waitFor(description: "source persistence-proof host layout") {
            sourceHost.view.bounds == expectedHostBounds
        }
        try await Self.waitFor(description: "fenced persistence-proof host layout") {
            fencedHost.view.bounds == expectedHostBounds
        }
        try #require(sourceHost.view.bounds == expectedHostBounds)
        try #require(fencedHost.view.bounds == expectedHostBounds)

        let badSourceFactory = NativeJSONCanvasAttachmentFactory { _ in Data("mismatched".utf8) }
        let sourceFailure = try Self.fallbackFailure {
            _ = try badSourceFactory.makeView(for: NativeJSONCanvasAttachmentInput.source(sourcePin))
        }
        #expect(sourceFailure == NativeJSONCanvasAttachmentFailure.source(
            input: sourcePin,
            reason: .digestMismatch))

        let oversizedFence = try Self.fence(
            bytes: Data(repeating: 0, count: JSONCanvasLimits.maximumInputByteCount + 1),
            pageID: page.id,
            pageVersionID: pageVersionID)
        let fencedFailure = try Self.fallbackFailure {
            _ = try factory.makeView(for: NativeJSONCanvasAttachmentInput.fenced(oversizedFence))
        }
        #expect(fencedFailure == NativeJSONCanvasAttachmentFailure.fenced(
            input: oversizedFence,
            reason: .oversizedInput))
        #expect(resolvedPins == [sourcePin])
        #expect(try Self.persistenceObservation(
            store: store,
            sourceID: storedSource.id,
            pageID: page.id,
            pageVersionID: pageVersionID) == before)
    }

    private static func waitFor(description: String, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while condition() == false {
            guard ContinuousClock.now < deadline else { throw HostedJSONCanvasAttachmentError.timeout(description) }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let hostedCanvasSize = CGSize(width: 520, height: 260)

    private static func host(_ rootView: AnyView) -> NSHostingController<AnyView> {
        let host = NSHostingController(rootView: AnyView(rootView.frame(
            width: hostedCanvasSize.width,
            height: hostedCanvasSize.height)))
        host.view.frame = .init(origin: .zero, size: hostedCanvasSize)
        host.view.layoutSubtreeIfNeeded()
        return host
    }

    private static func release(_ host: NSHostingController<AnyView>) {
        host.rootView = AnyView(EmptyView())
    }

    private static func source(bytes: Data) throws -> RendererEmbeddedContent.Source {
        try .init(
            sourceID: .init(rawValue: "01JHOSTEDSOURCE0000000000001"),
            sourceVersionID: .init(rawValue: "01JHOSTEDVERSION000000000001"),
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
    }

    private static func fence(bytes: Data) throws -> RendererEmbeddedContent.InlineArtifact {
        try fence(
            bytes: bytes,
            pageID: PageID(rawValue: "01JHOSTEDPAGE000000000000001"),
            pageVersionID: PageVersionID(rawValue: "01JHOSTEDPAGEVERSION00000001"))
    }

    private static func fence(
        bytes: Data,
        pageID: PageID,
        pageVersionID: PageVersionID
    ) throws -> RendererEmbeddedContent.InlineArtifact {
        let block = try MarkdownFencedBlock(
            documentIdentity: .init(pageID: pageID, pageVersionID: pageVersionID),
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: bytes)
        return try .init(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: try #require(block.blockID),
            fenceKind: .jsoncanvas,
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
    }

    private static func fallbackFailure(
        _ operation: () throws -> Void
    ) throws -> NativeJSONCanvasAttachmentFailure {
        do {
            try operation()
        } catch let failure as NativeJSONCanvasAttachmentFailure {
            return failure
        }
        throw HostedJSONCanvasAttachmentError.expectedFallbackFailure
    }

    private static func persistenceObservation(
        store: GRDBWikiStore,
        sourceID: SourceID,
        pageID: PageID,
        pageVersionID: PageVersionID
    ) throws -> JSONCanvasAttachmentPersistenceObservation {
        try .init(
            sourceVersions: store.contentVersionHistory(sourceID: sourceID),
            activeSourceVersion: store.activeContentVersion(sourceID: sourceID),
            sourceOrigin: store.sourceOrigin(sourceID: sourceID),
            activeExtractionProvenance: store.activeExtractionProvenance(sourceID: sourceID),
            pageVersions: store.pageVersionHistory(pageID: pageID),
            activePageVersionID: store.pageHeadVersionID(pageID: pageID),
            pageOrigin: store.pageOrigin(pageID: pageID),
            pageVersionSources: store.pageVersionSources(versionID: pageVersionID),
            sourceReferencingPageVersions: store.sourceReferencingPageVersions(sourceID: sourceID))
    }

    private static let canvas = Data("""
    {"nodes":[
      {"id":"first","type":"text","x":20,"y":10,"width":160,"height":80,"text":"First note"},
      {"id":"second","type":"text","x":220,"y":10,"width":160,"height":80,"text":"Second note"}
    ],"edges":[{"id":"edge","fromNode":"first","toNode":"second"}]}
    """.utf8)
}

private enum HostedJSONCanvasAttachmentError: Error {
    case timeout(String)
    case unexpectedSourcePin
    case expectedFallbackFailure
}

private struct JSONCanvasAttachmentPersistenceObservation: Equatable {
    let sourceVersions: [SourceVersion]
    let activeSourceVersion: SourceVersion?
    let sourceOrigin: SourceOrigin?
    let activeExtractionProvenance: ExtractionProvenance?
    let pageVersions: [PageVersionSummary]
    let activePageVersionID: PageVersionID?
    let pageOrigin: PageOrigin?
    let pageVersionSources: [PageVersionSource]
    let sourceReferencingPageVersions: [PageVersionID]
}
#endif

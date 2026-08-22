#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore
import WikiFSTypes

@Suite("JSON Canvas native attachment hosted interactions", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct JSONCanvasAttachmentHostedTests {
    @Test("source and fenced native attachments report genuine mouse selection and preserve their authorization forms")
    func sourceAndFencedAttachmentsMountAndSelect() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

        let source = try Self.source(bytes: Self.canvas)
        let pin = try NativeJSONCanvasAttachmentInput.SourcePin(validating: source)
        let fence = try Self.fence(bytes: Self.canvas)
        var resolvedPins: [NativeJSONCanvasAttachmentInput.SourcePin] = []
        let factory = NativeJSONCanvasAttachmentFactory { requestedPin in
            resolvedPins.append(requestedPin)
            return Self.canvas
        }
        var sourceSnapshots: [JSONCanvasInteractionSnapshot] = []
        var fencedSnapshots: [JSONCanvasInteractionSnapshot] = []
        let sourceHost = Self.host(try factory.makeView(for: .source(pin), onInteractionChange: { snapshot in
            sourceSnapshots.append(snapshot)
        }))
        let fencedHost = Self.host(try factory.makeView(for: .fenced(fence), onInteractionChange: { snapshot in
            fencedSnapshots.append(snapshot)
        }))
        defer {
            Self.release(sourceHost)
            Self.release(fencedHost)
        }

        let expectedHostBounds = CGRect(origin: .zero, size: Self.hostedCanvasSize)
        try await Self.waitFor(description: "source JSON Canvas host layout") {
            sourceHost.host.view.bounds == expectedHostBounds
        }
        try await Self.waitFor(description: "fenced JSON Canvas host layout") {
            fencedHost.host.view.bounds == expectedHostBounds
        }
        try #require(sourceHost.host.view.bounds == expectedHostBounds)
        try #require(fencedHost.host.view.bounds == expectedHostBounds)

        let sourcePoint = Self.firstNodePoint(in: sourceHost.host.view.bounds)
        let fencedPoint = Self.firstNodePoint(in: fencedHost.host.view.bounds)
        try await Self.sendClick(to: sourceHost, at: sourcePoint)
        try await Self.waitForSelection(
            in: sourceHost,
            point: sourcePoint,
            snapshot: { sourceSnapshots.last },
            description: "source JSON Canvas selection")
        try await Self.sendClick(to: fencedHost, at: fencedPoint)
        try await Self.waitForSelection(
            in: fencedHost,
            point: fencedPoint,
            snapshot: { fencedSnapshots.last },
            description: "fenced JSON Canvas selection")

        #expect(resolvedPins == [pin])
        let expectedSelection = try JSONCanvasNodeID(validating: "first")
        for snapshot in [try #require(sourceSnapshots.last), try #require(fencedSnapshots.last)] {
            #expect(snapshot.selectedNodeID == expectedSelection)
            #expect(snapshot.scale >= JSONCanvasLimits.minimumScale)
            #expect(snapshot.scale <= JSONCanvasLimits.maximumScale)
            #expect(abs(snapshot.translation.x) <= JSONCanvasLimits.maximumTranslationMagnitude)
            #expect(abs(snapshot.translation.y) <= JSONCanvasLimits.maximumTranslationMagnitude)
        }

        sourceHost.window.appearance = NSAppearance(named: .aqua)
        sourceHost.host.view.layoutSubtreeIfNeeded()
        fencedHost.window.appearance = NSAppearance(named: .darkAqua)
        fencedHost.host.view.layoutSubtreeIfNeeded()

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

    @Test("hosted source and fenced fallbacks preserve authorization and create no version or provenance activity")
    func hostedFallbacksAndInteractionsDoNotPersist() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        Self.prepareApplication()

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
        var sourceSnapshots: [JSONCanvasInteractionSnapshot] = []
        var fencedSnapshots: [JSONCanvasInteractionSnapshot] = []
        let sourceHost = Self.host(try factory.makeView(
            for: NativeJSONCanvasAttachmentInput.source(sourcePin),
            onInteractionChange: {
            sourceSnapshots.append($0)
        }))
        let fencedHost = Self.host(try factory.makeView(
            for: NativeJSONCanvasAttachmentInput.fenced(fenced),
            onInteractionChange: {
            fencedSnapshots.append($0)
        }))
        defer {
            Self.release(sourceHost)
            Self.release(fencedHost)
        }

        let expectedHostBounds = CGRect(origin: .zero, size: Self.hostedCanvasSize)
        try await Self.waitFor(description: "source persistence-proof host layout") {
            sourceHost.host.view.bounds == expectedHostBounds
        }
        try await Self.waitFor(description: "fenced persistence-proof host layout") {
            fencedHost.host.view.bounds == expectedHostBounds
        }
        try #require(sourceHost.host.view.bounds == expectedHostBounds)
        try #require(fencedHost.host.view.bounds == expectedHostBounds)

        let sourcePoint = Self.firstNodePoint(in: sourceHost.host.view.bounds)
        let fencedPoint = Self.firstNodePoint(in: fencedHost.host.view.bounds)
        try await Self.sendClick(to: sourceHost, at: sourcePoint)
        try await Self.waitForSelection(
            in: sourceHost,
            point: sourcePoint,
            snapshot: { sourceSnapshots.last },
            description: "source persistence-proof selection")
        try await Self.sendClick(to: fencedHost, at: fencedPoint)
        try await Self.waitForSelection(
            in: fencedHost,
            point: fencedPoint,
            snapshot: { fencedSnapshots.last },
            description: "fenced persistence-proof selection")

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
        #expect(sourceSnapshots.last?.selectedNodeID?.rawValue == "first")
        #expect(fencedSnapshots.last?.selectedNodeID?.rawValue == "first")
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
    private static let firstNodeOrigin = CGPoint(x: 20, y: 10)
    private static let firstNodeSize = CGSize(width: 160, height: 80)
    private static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        return application
    }()

    private static func host(_ rootView: AnyView) -> (host: NSHostingController<AnyView>, window: NSWindow) {
        let host = NSHostingController(rootView: AnyView(rootView.frame(
            width: hostedCanvasSize.width,
            height: hostedCanvasSize.height)))
        let window = NSWindow(
            contentRect: .init(origin: .zero, size: hostedCanvasSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.setContentSize(hostedCanvasSize)
        host.view.frame = .init(origin: .zero, size: hostedCanvasSize)
        host.view.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        return (host, window)
    }

    private static func release(_ hosted: (host: NSHostingController<AnyView>, window: NSWindow)) {
        hosted.host.rootView = AnyView(EmptyView())
        hosted.window.orderOut(nil)
        hosted.window.contentView = nil
    }

    private static func firstNodePoint(in bounds: CGRect) -> NSPoint {
        let firstNodeCenter = CGPoint(
            x: firstNodeOrigin.x + firstNodeSize.width / 2,
            y: firstNodeOrigin.y + firstNodeSize.height / 2)
        return NSPoint(
            x: firstNodeCenter.x,
            y: bounds.maxY - firstNodeCenter.y)
    }

    private static func sendClick(
        to hosted: (host: NSHostingController<AnyView>, window: NSWindow),
        at point: NSPoint
    ) async throws {
        try await prepareForMouseDelivery(to: hosted)
        let window = hosted.window
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1),
            let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
            pressure: 0)
        else {
            throw HostedJSONCanvasAttachmentError.eventConstruction(windowNumber: window.windowNumber)
        }
        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
    }

    private static func prepareForMouseDelivery(
        to hosted: (host: NSHostingController<AnyView>, window: NSWindow)
    ) async throws {
        let application = Self.application
        application.activate(ignoringOtherApps: true)
        hosted.window.makeKeyAndOrderFront(nil)
        hosted.host.view.layoutSubtreeIfNeeded()
        try await waitForWindowPresentation(hosted)
        // Reassert the matching window immediately before dispatching its
        // genuine mouse down/up pair; this never assumes two windows are key.
        application.activate(ignoringOtherApps: true)
        hosted.window.makeKeyAndOrderFront(nil)
        guard windowIsReadyForMouseDelivery(hosted) else {
            throw windowPresentationError(hosted)
        }
    }

    private static func waitForWindowPresentation(
        _ hosted: (host: NSHostingController<AnyView>, window: NSWindow)
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while windowIsReadyForMouseDelivery(hosted) == false {
            guard ContinuousClock.now < deadline else {
                throw windowPresentationError(hosted)
            }
            // Yield the main actor, then suspend rather than blocking a
            // cooperative executor thread while AppKit presents this window.
            try Task.checkCancellation()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func windowIsReadyForMouseDelivery(
        _ hosted: (host: NSHostingController<AnyView>, window: NSWindow)
    ) -> Bool {
        let window = hosted.window
        return Self.application.isActive &&
            window.isVisible &&
            window.isKeyWindow &&
            window.canBecomeKey &&
            window.screen != nil &&
            window.contentView === hosted.host.view &&
            hosted.host.view.window === window
    }

    private static func waitForSelection(
        in hosted: (host: NSHostingController<AnyView>, window: NSWindow),
        point: NSPoint,
        snapshot: @escaping @MainActor () -> JSONCanvasInteractionSnapshot?,
        description: String
    ) async throws {
        do {
            try await Self.waitFor(description: description) {
                snapshot()?.selectedNodeID?.rawValue == "first"
            }
        } catch {
            throw Self.interactionDeliveryError(
                hosted: hosted,
                point: point,
                snapshot: snapshot())
        }
    }

    private static func windowPresentationError(
        _ hosted: (host: NSHostingController<AnyView>, window: NSWindow)
    ) -> HostedJSONCanvasAttachmentError {
        let window = hosted.window
        return .windowPresentation(
            applicationIsActive: Self.application.isActive,
            windowNumber: window.windowNumber,
            isVisible: window.isVisible,
            isKeyWindow: window.isKeyWindow,
            canBecomeKey: window.canBecomeKey,
            hasScreen: window.screen != nil,
            contentViewAttached: window.contentView === hosted.host.view,
            hostViewAttached: hosted.host.view.window === window)
    }

    private static func interactionDeliveryError(
        hosted: (host: NSHostingController<AnyView>, window: NSWindow),
        point: NSPoint,
        snapshot: JSONCanvasInteractionSnapshot?
    ) -> HostedJSONCanvasAttachmentError {
        let hitTestClass = hosted.host.view.hitTest(point).map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderClass = hosted.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let application = NSApplication.shared
        return .interactionDelivery(
            applicationKeyWindowNumber: application.keyWindow?.windowNumber,
            applicationCurrentEventType: application.currentEvent.map { String(describing: $0.type) } ?? "nil",
            applicationCurrentEventWindowNumber: application.currentEvent?.windowNumber,
            windowFrame: hosted.window.frame,
            viewBounds: hosted.host.view.bounds,
            point: point,
            hitTestClass: hitTestClass,
            firstResponderClass: firstResponderClass,
            snapshot: snapshot)
    }

    private static func prepareApplication() {
        _ = Self.application
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
    case eventConstruction(windowNumber: Int)
    case windowPresentation(
        applicationIsActive: Bool,
        windowNumber: Int,
        isVisible: Bool,
        isKeyWindow: Bool,
        canBecomeKey: Bool,
        hasScreen: Bool,
        contentViewAttached: Bool,
        hostViewAttached: Bool)
    case interactionDelivery(
        applicationKeyWindowNumber: Int?,
        applicationCurrentEventType: String,
        applicationCurrentEventWindowNumber: Int?,
        windowFrame: CGRect,
        viewBounds: CGRect,
        point: NSPoint,
        hitTestClass: String,
        firstResponderClass: String,
        snapshot: JSONCanvasInteractionSnapshot?)
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

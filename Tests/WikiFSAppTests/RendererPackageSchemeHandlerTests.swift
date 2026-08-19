#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
@testable import WikiFS

@MainActor
struct RendererPackageSchemeHandlerTests {
    @Test("sends CSP MIME and nosniff headers before body bytes")
    func sendsHeadersBeforeBody() {
        let url = URL(string: "renderer-package://package/org.example.test/1.0.0/index.html")!
        let provider = StubResourceProvider(result: .success(.init(
            data: Data("<html></html>".utf8),
            mimeType: RendererMIMEType(rawValue: "text/html")!,
            isEntryDocument: true
        )))
        let handler = RendererPackageSchemeHandler(resourceProvider: provider)
        let task = RecordingTask(url: url)

        handler.serve(task)

        #expect(task.events == [.response, .data, .finish])
        #expect(task.response?.value(forHTTPHeaderField: RendererContentSecurityPolicy.headerName) == RendererContentSecurityPolicy.headerValue)
        #expect(task.response?.value(forHTTPHeaderField: RendererContentSecurityPolicy.noSniffHeaderName) == RendererContentSecurityPolicy.noSniffHeaderValue)
        #expect(task.response?.value(forHTTPHeaderField: "Content-Type") == "text/html")
        #expect(task.data == Data("<html></html>".utf8))
    }

    @Test("denied resources fail without response bytes")
    func deniedResourceFailsClosed() {
        let provider = StubResourceProvider(result: .failure(RendererPackageResourceError.undeclaredAsset))
        let handler = RendererPackageSchemeHandler(resourceProvider: provider)
        let task = RecordingTask(url: URL(string: "renderer-package://package/org.example.test/1.0.0/private.html")!)

        handler.serve(task)

        #expect(task.events == [.failure])
        #expect(task.data.isEmpty)
    }

    @Test("registry cancels and releases all outstanding tasks")
    func cancellationReleasesOutstandingTasks() {
        let registry = RendererPackageSchemeTaskRegistry()
        let first = RecordingTask(url: nil)
        let second = RecordingTask(url: nil)
        registry.begin(first)
        registry.begin(second)

        registry.cancelAll()

        #expect(registry.activeTaskCount == 0)
        #expect(first.events == [.failure])
        #expect(second.events == [.failure])
    }

    @Test("handler close cancels a task while its provider is serving")
    func closeCancelsOutstandingServe() {
        let url = URL(string: "renderer-package://package/org.example.test/1.0.0/index.html")!
        let task = RecordingTask(url: url)
        let provider = StubResourceProvider(result: .success(.init(
            data: Data("late body".utf8),
            mimeType: RendererMIMEType(rawValue: "text/html")!,
            isEntryDocument: true
        )))
        let handler = RendererPackageSchemeHandler(resourceProvider: provider)
        handler.onTaskRegistered = { _ in handler.close() }

        handler.serve(task)

        #expect(task.events == [.failure])
    }

    @Test("stopping a scheme task releases it without a terminal callback")
    func stoppingTaskSuppressesLaterCancellation() {
        let registry = RendererPackageSchemeTaskRegistry()
        let task = RecordingTask(url: nil)
        registry.begin(task)

        registry.stop(task)
        registry.cancelAll()

        #expect(registry.activeTaskCount == 0)
        #expect(task.events.isEmpty)
        #expect(task.stopCount == 1)
    }

    @Test("a stop during response prevents data and finish callbacks")
    func stopDuringResponsePreventsLaterCallbacks() {
        let url = URL(string: "renderer-package://package/org.example.test/1.0.0/index.html")!
        let registry = RendererPackageSchemeTaskRegistry()
        let provider = StubResourceProvider(result: .success(.init(
            data: Data("body".utf8), mimeType: RendererMIMEType(rawValue: "text/html")!, isEntryDocument: true
        )))
        let handler = RendererPackageSchemeHandler(resourceProvider: provider, taskRegistry: registry)
        let task = RecordingTask(url: url)
        task.onResponse = { registry.stop(task) }

        handler.serve(task)

        #expect(task.events == [.response])
        #expect(task.stopCount == 1)
    }
}

private struct StubResourceProvider: RendererPackageResourceProviding {
    let result: Result<RendererPackageResource, RendererPackageResourceError>

    init(result: Result<RendererPackageResource, RendererPackageResourceError>) {
        self.result = result
    }

    func resource(for url: URL) throws -> RendererPackageResource { try result.get() }
}

@MainActor
private final class RecordingTask: RendererPackageSchemeTask {
    enum Event: Equatable { case response, data, finish, failure }

    let requestURL: URL?
    private(set) var events: [Event] = []
    private(set) var response: HTTPURLResponse?
    private(set) var data = Data()
    private(set) var stopCount = 0
    var onResponse: (() -> Void)?

    init(url: URL?) { requestURL = url }

    func receive(response: HTTPURLResponse) {
        events.append(.response)
        self.response = response
        onResponse?()
    }

    func receive(data: Data) {
        events.append(.data)
        self.data.append(data)
    }

    func finish() { events.append(.finish) }
    func fail(_ error: any Error) { events.append(.failure) }
    func stop() { stopCount += 1 }
}
#endif

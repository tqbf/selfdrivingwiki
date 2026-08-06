import Foundation
import WebKit
import WikiFSCore

// pattern: Imperative Shell

/// A portable task facade used to prove scheme response ordering without a live
/// WebKit process. `RendererPackageSchemeHandler` adapts `WKURLSchemeTask` to it.
@MainActor
protocol RendererPackageSchemeTask: AnyObject {
    var requestURL: URL? { get }
    func receive(response: HTTPURLResponse)
    func receive(data: Data)
    func finish()
    func fail(_ error: any Error)
}

/// Main-actor bookkeeping for all active package-scheme tasks. Closing always
/// fails and releases every task that was registered but not completed.
@MainActor
final class RendererPackageSchemeTaskRegistry {
    private var tasks: [ObjectIdentifier: any RendererPackageSchemeTask] = [:]

    var activeTaskCount: Int { tasks.count }

    func begin(_ task: any RendererPackageSchemeTask) {
        tasks[ObjectIdentifier(task)] = task
    }

    func finish(_ task: any RendererPackageSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(task))
    }

    func cancelAll() {
        let outstanding = Array(tasks.values)
        tasks.removeAll()
        for task in outstanding { task.fail(RendererPackageSchemeTaskError.cancelled) }
    }
}

@MainActor
enum RendererPackageSchemeTaskError: Error {
    case cancelled
    case requestDenied
}

/// WebKit adapter for version-pinned renderer-package bytes. It only serves
/// `renderer-package:` resources and never turns an installed path into a
/// `file:` URL. Navigation policy and general subresource interception belong
/// to later session slices.
@MainActor
final class RendererPackageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resourceProvider: any RendererPackageResourceProviding
    private let taskRegistry: RendererPackageSchemeTaskRegistry
    private var webKitTasks: [ObjectIdentifier: WebKitTaskAdapter] = [:]

    init(
        resourceProvider: any RendererPackageResourceProviding,
        taskRegistry: RendererPackageSchemeTaskRegistry = .init()
    ) {
        self.resourceProvider = resourceProvider
        self.taskRegistry = taskRegistry
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            let key = ObjectIdentifier(urlSchemeTask as AnyObject)
            let task = WebKitTaskAdapter(task: urlSchemeTask)
            webKitTasks[key] = task
            serve(task)
            webKitTasks.removeValue(forKey: key)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            let key = ObjectIdentifier(urlSchemeTask as AnyObject)
            guard let task = webKitTasks.removeValue(forKey: key) else { return }
            taskRegistry.finish(task)
        }
    }

    func close() {
        taskRegistry.cancelAll()
        webKitTasks.removeAll()
    }

    /// Internal for focused task-ordering tests. The response is emitted before
    /// the first body byte on every successful resource response.
    func serve(_ task: any RendererPackageSchemeTask) {
        taskRegistry.begin(task)
        defer { taskRegistry.finish(task) }
        guard let url = task.requestURL else {
            task.fail(RendererPackageSchemeTaskError.requestDenied)
            return
        }
        do {
            let resource = try resourceProvider.resource(for: url)
            let response = try response(for: resource, url: url)
            task.receive(response: response)
            task.receive(data: resource.data)
            task.finish()
        } catch {
            task.fail(RendererPackageSchemeTaskError.requestDenied)
        }
    }

    private func response(for resource: RendererPackageResource, url: URL) throws -> HTTPURLResponse {
        let headers = [
            "Content-Type": resource.mimeType.rawValue,
            "Content-Length": "\(resource.data.count)",
            RendererContentSecurityPolicy.headerName: RendererContentSecurityPolicy.headerValue,
            RendererContentSecurityPolicy.noSniffHeaderName: RendererContentSecurityPolicy.noSniffHeaderValue,
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw RendererPackageSchemeTaskError.requestDenied
        }
        return response
    }
}

@MainActor
private final class WebKitTaskAdapter: RendererPackageSchemeTask {
    private let task: any WKURLSchemeTask

    init(task: any WKURLSchemeTask) { self.task = task }

    var requestURL: URL? { task.request.url }
    func receive(response: HTTPURLResponse) { task.didReceive(response) }
    func receive(data: Data) { task.didReceive(data) }
    func finish() { task.didFinish() }
    func fail(_ error: any Error) { task.didFailWithError(error) }
}

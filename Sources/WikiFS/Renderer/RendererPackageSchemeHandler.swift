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
    func stop()
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

    func cancel(_ task: any RendererPackageSchemeTask) {
        guard tasks.removeValue(forKey: ObjectIdentifier(task)) != nil else { return }
        task.fail(RendererPackageSchemeTaskError.cancelled)
    }

    /// WebKit has already ended this task. Release only our bookkeeping, then
    /// tell adapters to suppress all later WebKit callbacks.
    func stop(_ task: any RendererPackageSchemeTask) {
        guard tasks.removeValue(forKey: ObjectIdentifier(task)) != nil else { return }
        task.stop()
    }

    func contains(_ task: any RendererPackageSchemeTask) -> Bool {
        tasks[ObjectIdentifier(task)] != nil
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
    var onTaskRegistered: ((any RendererPackageSchemeTask) -> Void)?

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
            taskRegistry.stop(task)
        }
    }

    func close() {
        taskRegistry.cancelAll()
        webKitTasks.removeAll()
    }

    /// Internal for focused task-ordering tests. The task remains registered
    /// while its provider runs, so `close()` can cancel a reentrant serve.
    func serve(_ task: any RendererPackageSchemeTask) {
        taskRegistry.begin(task)
        onTaskRegistered?(task)
        guard taskRegistry.contains(task) else { return }
        guard let url = task.requestURL else {
            task.fail(RendererPackageSchemeTaskError.requestDenied)
            taskRegistry.finish(task)
            return
        }
        do {
            let resource = try resourceProvider.resource(for: url)
            guard taskRegistry.contains(task) else { return }
            let response = try response(for: resource, url: url)
            task.receive(response: response)
            guard taskRegistry.contains(task) else { return }
            task.receive(data: resource.data)
            guard taskRegistry.contains(task) else { return }
            task.finish()
            taskRegistry.finish(task)
        } catch {
            guard taskRegistry.contains(task) else { return }
            task.fail(RendererPackageSchemeTaskError.requestDenied)
            taskRegistry.finish(task)
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
    private enum State {
        case active
        case stopped
        case completed
    }

    private let task: any WKURLSchemeTask
    private var state: State = .active

    init(task: any WKURLSchemeTask) { self.task = task }

    var requestURL: URL? { task.request.url }
    func receive(response: HTTPURLResponse) {
        guard case .active = state else { return }
        task.didReceive(response)
    }

    func receive(data: Data) {
        guard case .active = state else { return }
        task.didReceive(data)
    }

    func finish() {
        guard case .active = state else { return }
        state = .completed
        task.didFinish()
    }

    func fail(_ error: any Error) {
        guard case .active = state else { return }
        state = .completed
        task.didFailWithError(error)
    }

    func stop() {
        guard case .active = state else { return }
        state = .stopped
    }
}

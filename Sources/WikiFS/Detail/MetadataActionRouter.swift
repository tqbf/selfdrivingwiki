import AppKit
import Foundation
import WikiFSCore

enum MetadataActionRouterError: Error, Equatable, Sendable {
    case unsafeURL(URL)
    case copyFailed
    case targetOpenFailed
}

/// The sole imperative seam for metadata rows. Presentation values carry only
/// typed targets; this router supplies window and clipboard side effects.
@MainActor
struct MetadataActionRouter {
    let openPage: (PageID) -> Bool
    let openSource: (SourceID) -> Bool
    let openChat: (ChatID) -> Bool
    let selectActivity: (QueueItem.ID) -> Bool
    let comparePageVersions: (PageID) -> Bool
    let compareSourceExtractions: (SourceID) -> Bool
    let copy: (String) -> Bool
    let openURL: (URL) -> Bool

    func route(link target: MetadataLinkTarget) throws {
        let opened: Bool
        switch target {
        case .page(let id): opened = openPage(id)
        case .source(let id): opened = openSource(id)
        case .chat(let id): opened = openChat(id)
        case .activity(let id): opened = selectActivity(id)
        case .url(let url):
            guard Self.isSafeURL(url) else { throw MetadataActionRouterError.unsafeURL(url) }
            opened = openURL(url)
        }
        guard opened else { throw MetadataActionRouterError.targetOpenFailed }
    }

    func route(action target: MetadataActionTarget) throws {
        switch target {
        case .comparePageVersions(let id):
            guard comparePageVersions(id) else { throw MetadataActionRouterError.targetOpenFailed }
        case .compareSourceExtractions(let id):
            guard compareSourceExtractions(id) else { throw MetadataActionRouterError.targetOpenFailed }
        case .copyIdentifier(let value):
            guard copy(value) else { throw MetadataActionRouterError.copyFailed }
        case .none:
            break
        }
    }

    nonisolated static func isSafeURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    static let systemClipboardCopy: (String) -> Bool = { value in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
}

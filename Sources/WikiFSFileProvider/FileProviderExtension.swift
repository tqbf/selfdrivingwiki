import FileProvider

/// The replicated File Provider extension principal class. Read-only: it serves
/// metadata, enumerates containers, and materializes file content on demand;
/// every mutating operation is rejected.
///
/// `@objc(FileProviderExtension)` pins the Objective-C runtime name so it
/// matches `NSExtensionPrincipalClass` in the appex Info.plist (otherwise Swift
/// would mangle it to `WikiFSFileProvider.FileProviderExtension`).
@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    /// The projection bound to THIS domain's wiki. The File Provider instantiates
    /// one extension per domain, so `domain.identifier` IS the wiki's ULID — we
    /// derive the per-wiki `<ulid>.sqlite` straight from it (no registry read),
    /// the multi-wiki crux from `plans/llm-wiki.md` Phase 0. Every request below
    /// goes through this instance, so it always reads the right wiki's DB.
    private let projection: Projection

    required init(domain: NSFileProviderDomain) {
        projection = Projection(wikiID: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let node = projection.node(for: identifier) {
            completionHandler(WikiFSItem(node: node), nil)
        } else {
            completionHandler(nil, noSuchItem)
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let data = projection.contents(for: itemIdentifier),
              let node = projection.node(for: itemIdentifier) else {
            completionHandler(nil, nil, noSuchItem)
            return Progress()
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try data.write(to: url)
            completionHandler(url, WikiFSItem(node: node), nil)
        } catch {
            completionHandler(nil, nil, error)
        }
        return Progress()
    }

    // MARK: Read-only — reject all mutations.

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, readOnly)
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, readOnly)
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(readOnly)
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        WikiFSEnumerator(container: containerItemIdentifier, projection: projection)
    }

    private var noSuchItem: NSError {
        NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue)
    }

    private var readOnly: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                userInfo: [NSLocalizedDescriptionKey: "Self Driving Wiki is read-only"])
    }
}

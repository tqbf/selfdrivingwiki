#if os(macOS)  // File Provider extension — macOS-only (FileProvider framework)
import FileProvider
import WikiFSTypes

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
        projection = Projection(wikiID: WikiID(rawValue: domain.identifier.rawValue))
        super.init()
    }

    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        do {
            if let node = try projection.checkedNode(for: identifier) {
                completionHandler(WikiFSItem(node: node), nil)
            } else {
                completionHandler(nil, noSuchItem)
            }
        } catch let failure as Projection.StoreUnavailable {
            // Unknown, not gone: `noSuchItem` would make the system delete it.
            completionHandler(nil, failure.fileProviderError)
        } catch {
            completionHandler(nil, error)
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        switch Self.contentsOutcome(for: itemIdentifier, in: projection) {
        case .failure(let error):
            completionHandler(nil, nil, error)
        case .success(let (data, node)):
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try data.write(to: url)
                completionHandler(url, WikiFSItem(node: node), nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        return Progress()
    }

    /// The bytes and node `fetchContents` serves, or the error it reports.
    /// `noSuchItem` (the system then deletes the item from disk) only when
    /// the store was read and the item does not exist. A store that could not
    /// be read, or an existing item whose bytes could not be produced, gives
    /// a retryable error (`Projection.StoreUnavailable.fileProviderError`).
    static func contentsOutcome(
        for identifier: NSFileProviderItemIdentifier,
        in projection: Projection
    ) -> Result<(Data, ProjectedNode), NSError> {
        let resolved: (node: ProjectedNode, data: Data?)?
        do {
            resolved = try projection.checkedContents(for: identifier)
        } catch let failure as Projection.StoreUnavailable {
            DebugLog.fileprovider("fetchContents \(identifier.rawValue): \(failure)")
            return .failure(failure.fileProviderError)
        } catch {
            return .failure(error as NSError)
        }
        guard let resolved else {
            return .failure(NSError(domain: NSFileProviderErrorDomain,
                                    code: NSFileProviderError.noSuchItem.rawValue))
        }
        guard let data = resolved.data else {
            let failure = Projection.StoreUnavailable(
                reason: "no content for existing item \(identifier.rawValue)")
            DebugLog.fileprovider("fetchContents \(failure)")
            return .failure(failure.fileProviderError)
        }
        return .success((data, resolved.node))
    }

    // MARK: Read-only — reject all mutations.

    /// Rejects every create, except one case: an item the daemon re-offers
    /// with `.mayAlreadyExist`.
    ///
    /// When `fileproviderd` rebuilds or reconciles a replica (for example
    /// after `reimportItems(below:)`), it treats every file already on disk as
    /// a new local item and calls `createItem` with `.mayAlreadyExist`. Those
    /// files came from this extension. If they are rejected as read-only, the
    /// daemon keeps each one as an orphaned local item that is not linked to
    /// the extension. The orphan then collides by name with the extension's
    /// own item, and the daemon throttles that item, so the folder stays
    /// incomplete (for example an empty `pages/by-id`).
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        do {
            if let node = try Self.existingNode(forReimportOf: itemTemplate, options: options, in: projection) {
                // Documents ask the daemon to fetch content, so the projection's
                // bytes replace whatever is on disk.
                completionHandler(WikiFSItem(node: node), [], !node.isFolder, nil)
            } else {
                completionHandler(nil, [], false, readOnly)
            }
        } catch let failure as Projection.StoreUnavailable {
            // A read-only rejection here would orphan the item. Ask the
            // daemon to retry the create when the store can be read.
            completionHandler(nil, [], false, failure.fileProviderError)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    /// The projected node that a reimported item matches, by parent and
    /// filename. `nil` when the create is a real user create (no
    /// `.mayAlreadyExist`) or the projection has no such item; both stay
    /// read-only rejections. Throws `Projection.StoreUnavailable` when the
    /// store could not be read.
    static func existingNode(
        forReimportOf itemTemplate: NSFileProviderItem,
        options: NSFileProviderCreateItemOptions,
        in projection: Projection
    ) throws -> ProjectedNode? {
        guard options.contains(.mayAlreadyExist) else { return nil }
        return try projection.child(named: itemTemplate.filename, in: itemTemplate.parentItemIdentifier)
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
#endif  // os(macOS)


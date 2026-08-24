import Foundation

/// One named on-disk bundle containing a `cordis.patch.yml` layer.
public struct ProfileBundle: Equatable, Sendable {
    public static let patchFileName = "cordis.patch.yml"

    public let name: String
    public let patch: PatchFile

    public init(name: String, data: Data) throws {
        self.name = name
        patch = try PatchFileCodec.decode(data: data)
    }

    public static func load(named name: String, from bundlesDirectory: URL) throws -> ProfileBundle {
        let url = bundlesDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(patchFileName, isDirectory: false)
        return try ProfileBundle(name: name, data: Data(contentsOf: url))
    }

    /// Resolves layers in their compatibility-contract order: base bundles,
    /// profile, home override, then the command-line overlay.
    public static func resolve(
        bundleNames: [String],
        profileName: String,
        in bundlesDirectory: URL,
        homePatchData: Data? = nil,
        overlay: String? = nil
    ) throws -> ResolvedProfile {
        var layers = try bundleNames.map { try load(named: $0, from: bundlesDirectory).patch }
        layers.append(try load(named: profileName, from: bundlesDirectory).patch)
        if let homePatchData {
            layers.append(try PatchFileCodec.decode(data: homePatchData))
        }
        if let overlay {
            layers.append(try PatchFileCodec.decode(overlay))
        }
        return ResolvedProfile(entries: PatchResolver.resolve(layers: layers))
    }
}

/// A shipped production profile and the catalog boundary that will boot it.
public enum ProductionProfileKind: String, Sendable {
    case app = "wikifs-app"
    case daemon = "wikid"
    case cli = "wikictl"
}

public enum ProductionProfileScope: String, Sendable {
    case process
    case wiki
}

/// Resolves the exact YAML layers used by production boots and config dumps.
/// `_scope` is loader metadata: it selects the process or per-wiki catalog and
/// is removed before plugin config decoding. Machine facts are applied last so
/// a user patch cannot redirect a production boot to another wiki database.
public enum ProductionProfileResolver {
    public static func shippedBundlesDirectory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "bundles", withExtension: nil) else {
            throw CordisLoaderError.missingShippedBundles
        }
        return url
    }

    public static func resolve(
        kind: ProductionProfileKind,
        scope: ProductionProfileScope,
        bundlesDirectory: URL? = nil,
        homeDirectory: URL? = nil,
        overlay: String? = nil,
        ambient: PatchFile = PatchFile(),
        fileManager: FileManager = .default
    ) throws -> ResolvedProfile {
        let bundlesDirectory = try bundlesDirectory ?? shippedBundlesDirectory()
        let homeURL = homeDirectory?.appendingPathComponent(ProfileBundle.patchFileName)
        let homeData = try homeURL.flatMap { url in
            fileManager.isReadableFile(atPath: url.path) ? try Data(contentsOf: url) : nil
        }
        var layers = try (kind == .cli ? [] : ["wikifs-base"]).map {
            try ProfileBundle.load(named: $0, from: bundlesDirectory).patch
        }
        layers.append(try ProfileBundle.load(named: kind.rawValue, from: bundlesDirectory).patch)
        if let homeData { layers.append(try PatchFileCodec.decode(data: homeData)) }
        if let overlay { layers.append(try PatchFileCodec.decode(overlay)) }

        // Replacement rows inherit the scope of the row they replace. Home and
        // command overlays therefore do not need to know about loader metadata.
        var inheritedScopes: [EntryID: ConfigValue] = [:]
        let scopedLayers = layers.map { layer in
            var result = layer
            result.entries = layer.entries.map { entry in
                var result = entry
                if let declared = result.config?["_scope"] {
                    inheritedScopes[result.id] = declared
                } else if let inherited = inheritedScopes[result.id] {
                    if result.config == nil { result.config = [:] }
                    result.config?["_scope"] = inherited
                }
                return result
            }
            for removed in layer.remove { inheritedScopes.removeValue(forKey: removed) }
            return result
        }
        let scoped = PatchResolver.resolve(layers: scopedLayers).compactMap { entry -> Entry? in
            guard case .string(let rawScope)? = entry.config?["_scope"], rawScope == scope.rawValue else { return nil }
            var result = entry
            result.config?.removeValue(forKey: "_scope")
            if result.config?.isEmpty == true { result.config = nil }
            return result
        }
        return ResolvedProfile(entries: PatchResolver.resolve(layers: [PatchFile(entries: scoped), ambient]))
    }
}

public struct ResolvedProfile: Equatable, Sendable {
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public func dump() throws -> String {
        try PatchFileCodec.encode(PatchFile(entries: entries))
    }
}

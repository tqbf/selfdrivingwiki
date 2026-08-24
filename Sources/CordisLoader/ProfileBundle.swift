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

public struct ResolvedProfile: Equatable, Sendable {
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public func dump() throws -> String {
        try PatchFileCodec.encode(PatchFile(entries: entries))
    }
}

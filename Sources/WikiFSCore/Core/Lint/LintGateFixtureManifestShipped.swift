import Foundation

/// The SHIPPED gate-fixture manifest (plan §6.13): a small versioned
/// resource in WikiFSCore carrying the gate-suite revision and the frozen
/// tuning/held-out fixture-set digests — never fixture bodies. The
/// evaluation tooling generates it from the canonical fixture manifests;
/// the coordinator requires its digests to match a configuration's
/// acceptance key, so a fixture update changes the key and invalidates all
/// prior evidence. Production needs no dependency on the eval target or
/// files under tmp/.
public struct LintGateFixtureManifestShipped: Codable, Equatable, Sendable {

    public struct SetDigest: Codable, Equatable, Sendable {
        public let name: String
        public let digest: String

        public init(name: String, digest: String) {
            self.name = name
            self.digest = digest
        }
    }

    public let revision: Int
    public let sets: [SetDigest]

    public init(revision: Int, sets: [SetDigest]) {
        self.revision = revision
        self.sets = sets
    }

    /// Load the shipped resource from the WikiFSCore bundle.
    public static func load() throws -> LintGateFixtureManifestShipped {
        guard let url = Bundle.module.url(
            forResource: "LintGateFixtureManifest", withExtension: "json") else {
            throw LintGateManifestError.missingResource
        }
        let decoder = JSONDecoder()
        return try decoder.decode(LintGateFixtureManifestShipped.self, from: try Data(contentsOf: url))
    }

    /// The fixture digest for `name`, or nil when the shipped revision does
    /// not carry that set.
    public func digest(named name: String) -> String? {
        sets.first { $0.name == name }?.digest
    }

    public enum LintGateManifestError: Error { case missingResource }
}

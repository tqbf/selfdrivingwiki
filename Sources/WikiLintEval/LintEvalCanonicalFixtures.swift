import Foundation

/// The CANONICAL gate fixture manifest (plan §6.5/§6.13): committed JSON in
/// this target, loaded by `inspect`, hashed into the shipped
/// `LintGateFixtureManifest.json` resource, and frozen before tuning. A
/// change to these files changes the digest, the acceptance key, and
/// therefore invalidates all prior gate evidence.
public enum LintEvalCanonicalFixtures {

    public enum CanonicalError: Error, Equatable {
        case missingResource(name: String)
    }

    /// Load the canonical gate manifest from this target's bundle.
    public static func loadGateManifest() throws -> LintEvalFixtureManifest {
        guard let url = Bundle.module.url(
            forResource: "canonical-gate-manifest", withExtension: "json",
            subdirectory: "Fixtures") else {
            throw CanonicalError.missingResource(name: "canonical-gate-manifest.json")
        }
        return try LintEvalFixtureManifest.load(from: try Data(contentsOf: url))
    }
}

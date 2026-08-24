import CordisLoader
import Foundation

public enum DumpConfigCommand {
    public struct Result: Equatable, Sendable {
        public let output: String
        public let note: String?

        public init(output: String, note: String? = nil) {
            self.output = output
            self.note = note
        }
    }

    public static func run(
        kind: ProductionProfileKind = .cli,
        scope: ProductionProfileScope = .process,
        bundlesDirectory: URL? = nil,
        homeDirectory: URL?,
        overlay: String? = nil,
        ambient: PatchFile = PatchFile(),
        fileManager: FileManager = .default
    ) throws -> Result {
        let homePatchURL = homeDirectory?.appendingPathComponent(ProfileBundle.patchFileName)
        let hasHomePatch = homePatchURL.map { fileManager.isReadableFile(atPath: $0.path) } ?? false
        let profile = try ProductionProfileResolver.resolve(
            kind: kind, scope: scope, bundlesDirectory: bundlesDirectory,
            homeDirectory: homeDirectory, overlay: overlay, ambient: ambient,
            fileManager: fileManager)
        let note = hasHomePatch ? nil : "# Note: no readable App Group cordis.patch.yml; showing the shipped profile."
        return Result(output: try profile.dump(), note: note)
    }
}

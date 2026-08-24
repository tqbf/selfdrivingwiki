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
        bundlesDirectory: URL,
        homeDirectory: URL?,
        overlay: String? = nil,
        fileManager: FileManager = .default
    ) throws -> Result {
        let homePatchURL = homeDirectory?.appendingPathComponent(ProfileBundle.patchFileName)
        let homeData: Data?
        var note: String?
        if let homePatchURL, fileManager.isReadableFile(atPath: homePatchURL.path) {
            homeData = try Data(contentsOf: homePatchURL)
        } else {
            homeData = nil
            note = "# Note: no readable App Group cordis.patch.yml; showing bundle-level wikictl profile."
        }
        let profile = try ProfileBundle.resolve(
            bundleNames: ["wikifs-base"],
            profileName: "wikictl",
            in: bundlesDirectory,
            homePatchData: homeData,
            overlay: overlay)
        return Result(output: try profile.dump(), note: note)
    }
}

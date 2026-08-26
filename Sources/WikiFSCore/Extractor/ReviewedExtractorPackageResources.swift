import Foundation

/// Resolves reviewed extractor package bytes from the current process bundle.
/// The app and the nested wikid XPC service receive identical resource trees.
public enum ReviewedExtractorPackageResources {
    public static func packageDirectory(named name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("ExtractorPackages", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true),
            Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "ExtractorPackages"),
        ]
        return candidates.compactMap { $0 }.first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: $0.path,
                isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}

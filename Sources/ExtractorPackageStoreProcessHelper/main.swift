import Foundation
import WikiFSCore
import WikiFSExtractorStore

private enum HelperError: Error {
    case invalidArguments
    case unexpectedMutationSuccess
}

@main
struct ExtractorPackageStoreProcessHelper {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else { throw HelperError.invalidArguments }
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

        switch mode {
        case "hold-lock":
            guard CommandLine.arguments.count == 5 else { throw HelperError.invalidArguments }
            let ready = URL(fileURLWithPath: CommandLine.arguments[3])
            let release = URL(fileURLWithPath: CommandLine.arguments[4])
            let layout = try ExtractorPackageStoreLayout(
                appGroupContainerRoot: root,
                processRole: .test)
            let coordinator = ExtractorPackageStoreCoordinator(layout: layout)
            try await coordinator.withExclusiveAccess {
                try Data().write(to: ready, options: .atomic)
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(15))
                while FileManager.default.fileExists(atPath: release.path) == false {
                    guard clock.now < deadline else { throw ExtractorPackageStoreError.lockTimedOut }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        case "read":
            guard CommandLine.arguments.count == 4 else { throw HelperError.invalidArguments }
            let result = URL(fileURLWithPath: CommandLine.arguments[3])
            let layout = try ExtractorPackageStoreLayout(
                appGroupContainerRoot: root,
                processRole: .daemon)
            let catalog = try ExtractorPackageCatalogReader(layout: layout).read()
            try Data(String(catalog.generation).utf8).write(to: result, options: .atomic)
        case "daemon-mutate":
            let layout = try ExtractorPackageStoreLayout(
                appGroupContainerRoot: root,
                processRole: .daemon)
            do {
                _ = try ExtractorPackageCatalogWriter.testing(layout: layout)
                throw HelperError.unexpectedMutationSuccess
            } catch ExtractorPackageStoreError.mutationForbidden {
                return
            }
        case "crash-with-lock":
            guard CommandLine.arguments.count == 4 else { throw HelperError.invalidArguments }
            let ready = URL(fileURLWithPath: CommandLine.arguments[3])
            let layout = try ExtractorPackageStoreLayout(
                appGroupContainerRoot: root,
                processRole: .test)
            let coordinator = ExtractorPackageStoreCoordinator(layout: layout)
            try await coordinator.withExclusiveAccess {
                try Data().write(to: ready, options: .atomic)
                exit(91)
            }
        default:
            throw HelperError.invalidArguments
        }
    }
}

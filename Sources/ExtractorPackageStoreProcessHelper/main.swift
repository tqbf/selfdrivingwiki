import Foundation
import WikiFSCore
import WikiFSExtractorStore

private enum HelperError: Error {
    case invalidArguments
    case unexpectedMutationSuccess
}

@main
struct ExtractorPackageStoreProcessHelper {
    static func main() async {
        // A throw out of an async @main dies by SIGTRAP ("Fatal error: Error
        // raised at top level"), which `Process.terminationStatus` reports as
        // 5 — indistinguishable from a runtime trap. Exit 3 names it as an
        // ordinary helper failure instead.
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("helper failed: \(error)\n".utf8))
            exit(3)
        }
    }

    private static func run() async throws {
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
                // Generous on purpose: the test drives this deadline from its
                // own side, and a loaded CI runner can take tens of seconds
                // between seeing `ready` and writing `release`. Dying early
                // releases the flock and turns the exclusion assertion into
                // a confusing spurious pass-through.
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(60))
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

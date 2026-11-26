import Foundation
import WikiFSCore

private enum HelperError: Error, CustomStringConvertible {
    case invalidArguments

    var description: String {
        switch self {
        case .invalidArguments: return "invalid arguments"
        }
    }
}

@main
struct ProviderConfigMutationHelper {
    static func main() async {
        do {
            try await run()
        } catch {
            // Report to stderr (the test pipes child stderr to nullDevice,
            // but a human rerunning the helper, or a test harness change,
            // then sees the reason). Exit 1 — a bare uncaught throw would
            // trap as SIGTRAP and read like a code bug instead of a
            // deadline/lock timeout.
            FileHandle.standardError.write(
                Data("ProviderConfigMutationHelper: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 7 else { throw HelperError.invalidArguments }

        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let readyURL = URL(fileURLWithPath: arguments[2])
        let goURL = URL(fileURLWithPath: arguments[3])
        let resultURL = URL(fileURLWithPath: arguments[4])
        let providerID = ProviderID(rawValue: arguments[5])
        let modelID = ModelID(rawValue: arguments[6])

        try Data().write(to: readyURL, options: .atomic)
        // The go-wait budget must comfortably exceed the parent's readiness
        // wait plus CI scheduling slop: on a 3-vCPU runner the parent writes
        // the go file after observing BOTH children's ready files, which can
        // land well past this child's own start. A 15 s budget raced that
        // window and the child exited 1 before the go signal — the cross-
        // process test then failed with missing result files.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while !FileManager.default.fileExists(atPath: goURL.path) {
            guard clock.now < deadline else {
                throw AgentProvidersConfigStoreError.lockAcquisitionTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let committed = try await AgentProvidersConfigStore(directory: directory).mutate {
            $0.settingSelectedModel(modelID, forProvider: providerID)
        }
        try Data(String(committed.generation).utf8).write(to: resultURL, options: .atomic)
    }
}

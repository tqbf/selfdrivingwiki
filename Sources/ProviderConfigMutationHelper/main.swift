import Foundation
import WikiFSCore

private enum HelperError: Error {
    case invalidArguments
}

@main
struct ProviderConfigMutationHelper {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 7 else { throw HelperError.invalidArguments }

        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let readyURL = URL(fileURLWithPath: arguments[2])
        let goURL = URL(fileURLWithPath: arguments[3])
        let resultURL = URL(fileURLWithPath: arguments[4])
        let providerID = ProviderID(rawValue: arguments[5])
        let modelID = ModelID(rawValue: arguments[6])

        try Data().write(to: readyURL, options: .atomic)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
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

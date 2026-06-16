import Foundation
import WikiFSCore

struct FileProviderSetupWarning: Identifiable, Sendable {
    enum Reason: Sendable {
        case installedAppMissing
        case bundledExtensionMissing
        case registeredPathMismatch([String])
        case registrationCommandFailed(String)
    }

    let id = UUID()
    let expectedAppURL: URL
    let expectedExtensionURL: URL
    let reason: Reason

    var message: String {
        switch reason {
        case .installedAppMissing:
            """
            File Provider mounts require the app at \(expectedAppURL.path), but that app is missing. \
            Run `make install`, then open the installed app.
            """
        case .bundledExtensionMissing:
            """
            The installed app is missing its File Provider extension at \(expectedExtensionURL.path). \
            Run `make install` to rebuild and reinstall the app.
            """
        case .registeredPathMismatch(let paths):
            """
            File Provider is not registered to the installed extension at \(expectedExtensionURL.path). \
            Current registration: \(paths.isEmpty ? "none" : paths.joined(separator: ", ")). \
            Run `make install`, then restart the app.
            """
        case .registrationCommandFailed(let details):
            """
            The app could not verify or repair its File Provider registration. \
            Run `make install`, then restart the app.

            \(details)
            """
        }
    }
}

enum FileProviderSetupVerifier {
    private static let providerID = "org.sockpuppet.WikiFS.FileProvider"
    private static let extensionName = "WikiFSFileProvider"
    private static let pluginKitURL = URL(fileURLWithPath: "/usr/bin/pluginkit")

    static func verifyAndRepairInstalledProvider() async -> FileProviderSetupWarning? {
        let expectedAppURL = URL(fileURLWithPath: AppInstallationPolicy.expectedAppPath)
            .standardizedFileURL
        let expectedExtensionURL = expectedAppURL
            .appendingPathComponent("Contents/PlugIns/\(extensionName).appex", isDirectory: true)
            .standardizedFileURL

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: expectedAppURL.path) else {
            return FileProviderSetupWarning(
                expectedAppURL: expectedAppURL,
                expectedExtensionURL: expectedExtensionURL,
                reason: .installedAppMissing)
        }
        guard fileManager.fileExists(atPath: expectedExtensionURL.path) else {
            return FileProviderSetupWarning(
                expectedAppURL: expectedAppURL,
                expectedExtensionURL: expectedExtensionURL,
                reason: .bundledExtensionMissing)
        }

        let paths = await registeredProviderPaths()
        if paths == [expectedExtensionURL.path] {
            return nil
        }

        if let failure = await repairRegistration(expectedExtensionURL: expectedExtensionURL) {
            return FileProviderSetupWarning(
                expectedAppURL: expectedAppURL,
                expectedExtensionURL: expectedExtensionURL,
                reason: .registrationCommandFailed(failure))
        }

        let repairedPaths = await registeredProviderPaths()
        guard repairedPaths == [expectedExtensionURL.path] else {
            return FileProviderSetupWarning(
                expectedAppURL: expectedAppURL,
                expectedExtensionURL: expectedExtensionURL,
                reason: .registeredPathMismatch(repairedPaths))
        }
        return nil
    }

    private static func repairRegistration(expectedExtensionURL: URL) async -> String? {
        for path in await registeredProviderPaths() where path != expectedExtensionURL.path {
            _ = await runPluginKit(["-r", path])
        }
        let add = await runPluginKit(["-a", expectedExtensionURL.path])
        guard add.exitCode == 0 else { return add.diagnostic }
        _ = await runPluginKit(["-e", "use", "-i", providerID, "-p", "com.apple.fileprovider-nonui"])
        return nil
    }

    private static func registeredProviderPaths() async -> [String] {
        let result = await runPluginKit([
            "-m", "-p", "com.apple.fileprovider-nonui", "-i", providerID, "-A", "-D", "-vvv",
        ])
        guard result.exitCode == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let marker = "Path = "
                guard let range = line.range(of: marker) else { return nil }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    private static func runPluginKit(_ arguments: [String]) async -> ProcessResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = pluginKitURL
            process.arguments = arguments

            let output = Pipe()
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                return ProcessResult(exitCode: process.terminationStatus, output: text)
            } catch {
                return ProcessResult(exitCode: 1, output: error.localizedDescription)
            }
        }.value
    }

    private struct ProcessResult: Sendable {
        let exitCode: Int32
        let output: String

        var diagnostic: String {
            output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

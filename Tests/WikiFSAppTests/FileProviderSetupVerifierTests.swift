#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

struct FileProviderSetupVerifierTests {
    @Test func missingInstalledAppReturnsWarning() async {
        let warning = await FileProviderSetupVerifier.verifyAndRepairInstalledProvider(
            fileExists: { _ in false },
            runCommand: { _ in
                AsyncProcessResult(terminationStatus: 0, output: .combined(Data()))
            })

        guard case .installedAppMissing? = warning?.reason else {
            Issue.record("Expected installedAppMissing warning")
            return
        }
    }

    @Test func repairsRegistrationInExpectedOrder() async {
        let expectedAppURL = URL(fileURLWithPath: AppInstallationPolicy.expectedAppPath)
            .standardizedFileURL
        let expectedExtensionURL = expectedAppURL
            .appendingPathComponent("Contents/PlugIns/WikiFSFileProvider.appex", isDirectory: true)
            .standardizedFileURL

        /// `@unchecked Sendable` is correct because `lock` serializes the
        /// mutable `commands` array across async test code and injected hooks.
        // swiftlint:disable:next unchecked_sendable
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var commands: [[String]] = []

            func append(_ arguments: [String]) {
                lock.lock()
                commands.append(arguments)
                lock.unlock()
            }
        }

        let recorder = Recorder()
        let warning = await FileProviderSetupVerifier.verifyAndRepairInstalledProvider(
            fileExists: { url in
                url == expectedAppURL || url == expectedExtensionURL
            },
            runCommand: { request in
                recorder.append(request.arguments)
                if request.arguments.contains("-m") {
                    if recorder.commands.count <= 2 {
                        let output = "Path = /Applications/Old.app/Contents/PlugIns/WikiFSFileProvider.appex\n"
                        return AsyncProcessResult(terminationStatus: 0, output: .combined(Data(output.utf8)))
                    }
                    let output = "Path = \(expectedExtensionURL.path)\n"
                    return AsyncProcessResult(terminationStatus: 0, output: .combined(Data(output.utf8)))
                }
                return AsyncProcessResult(terminationStatus: 0, output: .combined(Data()))
            })

        #expect(warning == nil)
        #expect(recorder.commands == [
            ["-m", "-p", "com.apple.fileprovider-nonui", "-i", WikiIdentifiers.fileProviderID, "-A", "-D", "-vvv"],
            ["-m", "-p", "com.apple.fileprovider-nonui", "-i", WikiIdentifiers.fileProviderID, "-A", "-D", "-vvv"],
            ["-r", "/Applications/Old.app/Contents/PlugIns/WikiFSFileProvider.appex"],
            ["-a", expectedExtensionURL.path],
            ["-e", "use", "-i", WikiIdentifiers.fileProviderID, "-p", "com.apple.fileprovider-nonui"],
            ["-m", "-p", "com.apple.fileprovider-nonui", "-i", WikiIdentifiers.fileProviderID, "-A", "-D", "-vvv"],
        ])
    }

    @Test func nonzeroAddReturnsDiagnosticWarning() async {
        let expectedAppURL = URL(fileURLWithPath: AppInstallationPolicy.expectedAppPath)
            .standardizedFileURL
        let expectedExtensionURL = expectedAppURL
            .appendingPathComponent("Contents/PlugIns/WikiFSFileProvider.appex", isDirectory: true)
            .standardizedFileURL

        let warning = await FileProviderSetupVerifier.verifyAndRepairInstalledProvider(
            fileExists: { url in
                url == expectedAppURL || url == expectedExtensionURL
            },
            runCommand: { request in
                if request.arguments.contains("-m") {
                    return AsyncProcessResult(
                        terminationStatus: 0,
                        output: .combined(Data("Path = /Applications/Old.app/Contents/PlugIns/WikiFSFileProvider.appex\n".utf8)))
                }
                if request.arguments.contains("-a") {
                    return AsyncProcessResult(
                        terminationStatus: 2,
                        output: .combined(Data("failed to register".utf8)))
                }
                return AsyncProcessResult(terminationStatus: 0, output: .combined(Data()))
            })

        #expect(warning != nil)
        guard case .registrationCommandFailed(let details)? = warning?.reason else {
            Issue.record("Expected registrationCommandFailed warning")
            return
        }
        #expect(details.contains("failed to register"))
    }
}
#endif

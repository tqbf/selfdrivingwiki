// pattern: Imperative Shell

import Foundation
import WikiFSCore

enum DaemonGitRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    enum Failure: Error, LocalizedError, Sendable {
        case unavailable(String)
        case failed(arguments: [String], output: Output)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message):
                return message
            case .failed(let arguments, let output):
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let command = (["git"] + arguments).joined(separator: " ")
                return detail.isEmpty
                    ? "git command failed (status \(output.status)): \(command)"
                    : "git command failed (status \(output.status)): \(detail)"
            }
        }
    }

    static func run(_ arguments: [String]) async throws -> Output {
        let resolution = await PathPreflight.resolveOnLoginShell(
            executable: "git",
            installHint: "Install the Xcode Command Line Tools")
        guard case .found(let path) = resolution else {
            if case .missing(let reason) = resolution { throw Failure.unavailable(reason) }
            throw Failure.unavailable("git is not available")
        }

        let result = try await AsyncProcessRunner.run(AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments))
        return Output(
            status: result.terminationStatus,
            stdout: String(decoding: result.stdoutData, as: UTF8.self),
            stderr: String(decoding: result.stderrData, as: UTF8.self))
    }

    static func requireSuccess(_ arguments: [String]) async throws -> String {
        let output = try await run(arguments)
        guard output.status == 0 else { throw Failure.failed(arguments: arguments, output: output) }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

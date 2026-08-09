// pattern: Functional Core

import Foundation

enum CodeHighlightBenchmarkCommand {
    static let nestedScalaProbe = "probe-nested-scala"

    struct Options: Equatable {
        let outputPath: String
        let head: String
        let tree: String
        let base: String
    }

    enum Error: LocalizedError, Equatable {
        case missingMode
        case unsupportedMode(String)
        case missingValue(String)
        case unexpectedArgument(String)
        case duplicateArgument(String)
        case missingArgument(String)
        case invalidSHA(String)

        var errorDescription: String? {
            switch self {
            case .missingMode:
                "missing benchmark mode"
            case .unsupportedMode(let mode):
                "unsupported benchmark mode: \(mode)"
            case .missingValue(let option):
                "missing value for \(option)"
            case .unexpectedArgument(let argument):
                "unexpected benchmark argument: \(argument)"
            case .duplicateArgument(let option):
                "duplicate benchmark argument: \(option)"
            case .missingArgument(let option):
                "missing required benchmark argument: \(option)"
            case .invalidSHA(let option):
                "invalid 40-character lowercase Git SHA for \(option)"
            }
        }
    }

    static func parse(arguments: [String]) throws -> Options {
        guard let mode = arguments.first else { throw Error.missingMode }
        guard mode == nestedScalaProbe else { throw Error.unsupportedMode(mode) }

        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard ["--output", "--head", "--tree", "--base"].contains(option) else {
                throw Error.unexpectedArgument(option)
            }
            guard index + 1 < arguments.count else { throw Error.missingValue(option) }
            guard values[option] == nil else { throw Error.duplicateArgument(option) }
            values[option] = arguments[index + 1]
            index += 2
        }

        guard let outputPath = values["--output"] else { throw Error.missingArgument("--output") }
        guard let head = values["--head"] else { throw Error.missingArgument("--head") }
        guard let tree = values["--tree"] else { throw Error.missingArgument("--tree") }
        guard let base = values["--base"] else { throw Error.missingArgument("--base") }
        for (option, value) in [("--head", head), ("--tree", tree), ("--base", base)] {
            guard isLowercaseGitSHA(value) else { throw Error.invalidSHA(option) }
        }
        return Options(outputPath: outputPath, head: head, tree: tree, base: base)
    }

    private static func isLowercaseGitSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
    }
}

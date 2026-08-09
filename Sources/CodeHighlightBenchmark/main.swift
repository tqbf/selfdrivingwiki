// pattern: Imperative Shell

import Darwin
import Foundation

do {
    let options = try CodeHighlightBenchmarkCommand.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    try CodeHighlightBenchmarkRunner.run(options: options)
} catch {
    let message = "CodeHighlightBenchmark: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}

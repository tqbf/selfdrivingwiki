import ExtractorPackageToolCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
enum ExtractorPackageToolMain {
    static func main() {
        do {
            let output = try ExtractorPackageToolExecutor().execute(
                arguments: Array(CommandLine.arguments.dropFirst()))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(output))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch let failure as ExtractorPackageToolFailure {
            FileHandle.standardError.write(Data("extractor-package-tool: \(failure.diagnostic)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(Data("extractor-package-tool: validation failed\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

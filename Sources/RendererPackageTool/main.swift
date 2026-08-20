import Foundation
import RendererPackageToolCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
enum RendererPackageToolMain {
    static func main() {
        do {
            let output = try RendererPackageToolExecutor().execute(
                arguments: Array(CommandLine.arguments.dropFirst()))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(output))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch let failure as RendererPackageToolFailure {
            FileHandle.standardError.write(Data("RendererPackageTool: \(failure.diagnostic)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(Data("RendererPackageTool: validation failed\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

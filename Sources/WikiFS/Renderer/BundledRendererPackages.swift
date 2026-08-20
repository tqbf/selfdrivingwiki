#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell

/// Locates the reviewed package that SwiftPM copied into the application
/// resource bundle. The source checkout is deliberately not a runtime input.
enum BundledRendererPackages {
    static let excalidrawPackageID: RendererPackageID = {
        do { return try RendererPackageID(validating: "org.selfdrivingwiki.excalidraw-readonly") }
        catch { preconditionFailure("Invalid bundled Excalidraw package ID: \(error)") }
    }()

    static let excalidrawVersion: RendererPackageVersion = {
        // Bumped with the package bytes: an installed version pins its exact
        // hash, so a changed asset at the same version fails closed and the
        // machine keeps the old package.
        do { return try RendererPackageVersion(validating: "1.0.1") }
        catch { preconditionFailure("Invalid bundled Excalidraw version: \(error)") }
    }()

    static let excalidrawRegistrationID: RendererRegistrationID = {
        do { return try RendererRegistrationID(validating: "excalidraw") }
        catch { preconditionFailure("Invalid bundled Excalidraw registration ID: \(error)") }
    }()

    static func excalidrawResourceURL() -> URL? {
        Bundle.main.url(forResource: "Excalidraw", withExtension: nil, subdirectory: "RendererPackages")
            ?? Bundle.main.url(forResource: "Excalidraw", withExtension: nil)
            ?? Bundle.module.url(forResource: "Excalidraw", withExtension: nil, subdirectory: "RendererPackages")
            ?? Bundle.module.url(forResource: "Excalidraw", withExtension: nil)
    }
}
#endif

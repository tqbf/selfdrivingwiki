import Foundation
import Testing
@testable import WikiFSCore

@Suite("Renderer package documentation", .serialized, .timeLimit(.minutes(1)))
struct RendererPackageDocumentationTests {
    @Test("maintainer skill and staged guide state machine-wide availability")
    func maintainerSkillAndGuideDescribeCurrentAvailabilityPolicy() throws {
        let root = repositoryRoot()
        let skill = try String(contentsOf: root.appending(path: "docs/skills/renderer-package-maintainer/SKILL.md"), encoding: .utf8)
        let guide = try String(contentsOf: root.appending(path: "docs/skills/renderer-package-maintainer/references/current-package-guide.md"), encoding: .utf8)
        let package = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let guideLoader = try String(contentsOf: root.appending(path: "Sources/WikiFSCore/Core/RendererPackageGuide.swift"), encoding: .utf8)

        #expect(skill.contains("name: renderer-package-maintainer"))
        #expect(skill.contains("description: Maintain Self Driving Wiki static renderer packages."))
        #expect(skill.contains("Every compatible validated package is available to every wiki."))
        #expect(guide.contains("org.selfdrivingwiki.excalidraw-readonly"))
        #expect(guide.contains("Every compatible validated installed renderer is available to every wiki."))
        #expect(guide.contains("renderer_wiki_enablement"))
        #expect(guide.contains("input.read"))
        #expect(guide.contains("5ce39d66a927d4e2933dc6a637a9c54eee55a1d54da48b87791b0d90bd23022b"))
        #expect(package.contains("renderer-package-maintainer/references/current-package-guide.md"))
        #expect(package.contains("RendererPackages/Excalidraw"))
        #expect(guideLoader.contains("Bundle.main.url(forResource: \"current-package-guide\", withExtension: \"md\")"))
        #expect(RendererPackageGuide.text.contains("Every compatible validated installed renderer is available to every wiki."))
        #expect(!guide.contains("Enabled for This Wiki"))
        #expect(!guide.contains("disabled by default per wiki"))
    }

    @Test("app packaging copies the guide beside the executable resources")
    func appPackagingCopiesGuideIntoRuntimeBundles() throws {
        let root = repositoryRoot()
        let buildScript = try String(contentsOf: root.appending(path: "build.sh"), encoding: .utf8)

        #expect(buildScript.contains("cp \"${SPM_RESOURCE_BUNDLE}/current-package-guide.md\" \"${RESOURCES_DIR}/\""))
        #expect(buildScript.contains("cp \"${SPM_RESOURCE_BUNDLE}/current-package-guide.md\" \"${APPEX_CONTENTS}/Resources/\""))
        #expect(buildScript.contains("cp \"${SPM_RESOURCE_BUNDLE}/current-package-guide.md\" \"${DAEMON_XPC_CONTENTS}/Resources/\""))
        #expect(buildScript.contains("${BIN_DIR}/WikiFS_WikiFS.bundle"))
        #expect(buildScript.contains("cp -R \"${SPM_APP_RESOURCE_BUNDLE}/Excalidraw\" \"${RESOURCES_DIR}/RendererPackages/\""))
    }

    @Test("documented two-file example has a valid manifest hash")
    func documentedTwoFileExampleHasAValidManifestHash() throws {
        let root = URL.temporaryDirectory.appending(path: "renderer-package-guide-example-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Renderer package guide example fixture cleanup failed.") }
        }
        let packageRoot = root.appending(path: "example")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let html = Data("<!doctype html><meta charset=\"utf-8\"><title>Example</title><p>Read-only renderer.</p>".utf8)
        try html.write(to: packageRoot.appending(path: "index.html"))
        let digest = RendererSHA256.digest(html)
        #expect(digest.hex == "5ce39d66a927d4e2933dc6a637a9c54eee55a1d54da48b87791b0d90bd23022b")

        let packageID = try RendererPackageID(validating: "org.example.readonly")
        let version = try RendererPackageVersion(validating: "1.0.0")
        let path = try RendererRelativePath(validating: "index.html")
        let asset = RendererAsset(path: path, digest: digest)
        let descriptor = try RendererDescriptor(
            reference: .init(packageID: packageID, version: version, registrationID: try RendererRegistrationID(validating: "example")),
            displayName: "Example",
            implementation: .webPackage(.init(path: path)),
            matchers: [.extensionFallback(try RendererFileExtension(validating: "example"))],
            presentations: [.web],
            approvedAssets: [asset],
            capabilities: [.inputRead],
            sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 1_024),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 0)
        let manifest = try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [asset])
        try manifest.canonicalJSON().write(to: packageRoot.appending(path: "manifest.json"))

        _ = try RendererPackageValidator(packageRoot: root).validate(directory: packageRoot)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

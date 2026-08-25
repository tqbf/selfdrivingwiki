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
        let stateReference = try String(contentsOf: root.appending(path: "docs/skills/renderer-package-maintainer/references/wiki-state-chat-reference.md"), encoding: .utf8)
        let package = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let guideLoader = try String(contentsOf: root.appending(path: "Sources/WikiFSCore/Core/RendererPackageGuide.swift"), encoding: .utf8)

        #expect(skill.contains("name: renderer-package-maintainer"))
        #expect(skill.contains("description: Create and maintain Self Driving Wiki static renderer packages."))
        #expect(skill.contains("Every compatible validated package is available to every wiki."))
        #expect(skill.contains("swift run RendererPackageTool validate <folder>"))
        #expect(skill.contains("The validation tool does not install or activate the package."))
        #expect(guide.contains("org.selfdrivingwiki.excalidraw-readonly"))
        #expect(guide.contains("Every compatible validated installed renderer is available to every wiki."))
        #expect(guide.contains("renderer_wiki_enablement"))
        #expect(guide.contains("input.read"))
        #expect(guide.contains("../assets/minimal-renderer-package/"))
        #expect(guide.contains("swift run RendererPackageTool validate <package-folder>"))
        #expect(stateReference.contains("every compatible validated installed renderer available to every wiki"))
        #expect(stateReference.contains("This short reference is context for wiki operations."))
        #expect(!package.contains("renderer-package-maintainer/references/current-package-guide.md"))
        #expect(package.contains("renderer-package-maintainer/references/wiki-state-chat-reference.md"))
        #expect(package.contains("RendererPackages/Excalidraw"))
        #expect(guideLoader.contains("Bundle.main.url(forResource: \"wiki-state-chat-reference\", withExtension: \"md\")"))
        #expect(RendererPackageGuide.text.contains("every compatible validated installed renderer available to every wiki"))
        #expect(!guide.contains("Enabled for This Wiki"))
        #expect(!guide.contains("disabled by default per wiki"))
    }

    @Test("app packaging copies the guide beside the executable resources")
    func appPackagingCopiesGuideIntoRuntimeBundles() throws {
        let root = repositoryRoot()
        let buildScript = try String(contentsOf: root.appending(path: "build.sh"), encoding: .utf8)

        #expect(buildScript.contains("cp \"${SPM_RESOURCE_BUNDLE}/wiki-state-chat-reference.md\" \"${RESOURCES_DIR}/\""))
        #expect(buildScript.contains("cp \"${SPM_RESOURCE_BUNDLE}/wiki-state-chat-reference.md\" \"${APPEX_CONTENTS}/Resources/\""))
        #expect(buildScript.contains("cp \"${SPM_RESOURCE_BUNDLE}/wiki-state-chat-reference.md\" \"${DAEMON_XPC_CONTENTS}/Resources/\""))
        #expect(buildScript.contains("${BIN_DIR}/WikiFS_WikiFS.bundle"))
        #expect(buildScript.contains("cp -R \"${SPM_APP_RESOURCE_BUNDLE}/Excalidraw\" \"${RESOURCES_DIR}/RendererPackages/\""))
    }

    @Test("minimal skill template validates with the production validator")
    func minimalSkillTemplateValidatesWithProductionValidator() throws {
        let root = URL.temporaryDirectory.appending(path: "renderer-package-template-validation-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Renderer package template validation cleanup failed.") }
        }

        let validated = try RendererPackageValidator(
            packageRoot: root.appending(path: "packages"),
            stagingRoot: root.appending(path: "staging"))
            .validate(directory: minimalTemplateRoot())

        #expect(validated.manifest.packageID.rawValue == "org.example.readonly")
        #expect(validated.manifest.version.rawValue == "1.0.0")
        #expect(validated.manifest.descriptors.map(\.reference.registrationID.rawValue) == ["example"])
    }

    @Test("minimal skill template has exact digest and semantic read-only HTML")
    func minimalSkillTemplateHasSemanticReadOnlyHTML() throws {
        let template = minimalTemplateRoot()
        let htmlData = try Data(contentsOf: template.appending(path: "index.html"))
        let html = try #require(String(data: htmlData, encoding: .utf8))
        let manifest = try JSONDecoder().decode(
            RendererManifest.self,
            from: Data(contentsOf: template.appending(path: "manifest.json")))
        let expectedDigest = RendererSHA256.digest(htmlData)

        #expect(expectedDigest.hex == "3fd4edb473cf5a4617fc44a8d1c42f708a274122d7e2c7b424931dc97ffd0f33")
        #expect(manifest.assets == [RendererAsset(path: try RendererRelativePath(validating: "index.html"), digest: expectedDigest)])
        #expect(manifest.descriptors.first?.approvedAssets == manifest.assets)
        #expect(html.contains("<html lang=\"en\">"))
        #expect(html.contains("<title>Example renderer</title>"))
        #expect(html.contains("<main>"))
        #expect(html.contains("<h1>Example renderer</h1>"))
        #expect(html.contains("This read-only renderer displays local package content."))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<form"))
    }

    @Test("renderer documentation records syntax-owned roles and compatibility")
    func rendererDocumentationRecordsEmbeddingRoles() throws {
        let root = repositoryRoot()
        let index = try String(contentsOf: root.appending(path: "docs/user-guide/README.md"), encoding: .utf8)
        let guide = try String(contentsOf: root.appending(path: "docs/user-guide/renderer-packages.md"), encoding: .utf8)
        let design = try String(contentsOf: root.appending(path: "plans/dynamic-inline-renderer-attachments.md"), encoding: .utf8)
        let plan = try String(contentsOf: root.appending(path: "PLAN.md"), encoding: .utf8)

        #expect(index.contains("[Renderer packages](renderer-packages.md)"))
        #expect(plan.contains("[`docs/user-guide/`](docs/user-guide/README.md)"))
        #expect(guide.contains("The app does not use the selected source folder after import."))
        #expect(guide.contains("Every compatible installed renderer is available to every wiki on this Mac."))
        #expect(guide.contains("It does not accept ZIP files, other archives, remote catalogs, signing services, or network installation."))
        #expect(guide.contains("It does not delete source data or source preferences."))
        #expect(!guide.contains("destination picker"))
        #expect(guide.contains("You do not enable a package for each wiki."))
        #expect(guide.contains("```mermaid \"System architecture\""))
        #expect(guide.contains("![System architecture](images/architecture.canvas)"))
        #expect(guide.contains("48,384-byte limit"))
        #expect(guide.contains("A fifth row stays collapsed"))
        #expect(guide.contains("supportedEmbeddingRoles"))
        #expect(guide.contains("inlineContent"))
        #expect(guide.contains("disclosureRow"))
        #expect(guide.contains("Revision 1 packages never receive `inlineContent` authority."))
        #expect(design.contains("SourceVersionID"))
        #expect(design.contains("SourceMarkdownVersionID"))
        #expect(design.contains("separate document budget"))
        #expect(design.contains("six-state lifecycle") || design.contains("`fallback`, `eligible`"))
        #expect(plan.contains("plans/typed-markdown-embed-pipeline.md"))
        #expect(plan.contains("Images and media stay inline"))
    }

    private func minimalTemplateRoot() -> URL {
        repositoryRoot().appending(
            path: "docs/skills/renderer-package-maintainer/assets/minimal-renderer-package")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

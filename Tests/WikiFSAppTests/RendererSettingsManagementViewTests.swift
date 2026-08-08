#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct RendererSettingsManagementViewTests {
    @Test("settings surface exposes the approved management scopes and copy")
    func settingsSurfaceUsesApprovedScopesAndCopy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/WikiFS/Settings/RendererSettingsView.swift"),
            encoding: .utf8)

        #expect(source.contains("Installed on This Mac"))
        #expect(source.contains("Enabled for This Wiki"))
        #expect(source.contains(RendererSettingsPackagePicker.installButtonTitle))
        #expect(source.contains(RendererSettingsPackagePicker.v1FormatMessage))
        #expect(source.contains("Source data and wiki preferences were preserved"))
        #expect(source.contains(".font(.body)"))
        #expect(!source.contains(".font(.system(size:"))
    }
}
#endif

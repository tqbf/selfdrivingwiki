import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Settings → **Extraction** tab (thin wrapper). The actual backend selection
/// UI lives in `ExtractionBackendSettingsView`, extracted in #449 so it can
/// appear both here in Settings and in the Extraction Queue activity window's
/// gear button sheet.
///
/// The `launcher` parameter was historically needed to observe extraction-in-
/// progress state; `ExtractionBackendSettingsView` now reads that via
/// `@Environment(QueueActivityTracker.self)` instead, so the launcher is
/// accepted for API compatibility but no longer passed through.
struct ExtractionSettingsView: View {
    let containerDirectory: URL
    let launcher: AgentLauncher

    init(
        containerDirectory: URL,
        launcher: AgentLauncher,
        credentialStore: any ExtractionCredentialStore = KeychainExtractionCredentialStore(),
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher()
    ) {
        self.containerDirectory = containerDirectory
        self.launcher = launcher
    }

    var body: some View {
        ExtractionBackendSettingsView(containerDirectory: containerDirectory)
    }
}

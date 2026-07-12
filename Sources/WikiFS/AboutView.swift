import SwiftUI
import WikiFSCore

/// Settings → About tab: shows app name, version, build, and git SHA. Read-only
/// — all values are baked in at build time by `tools/versiongen/main.swift` and
/// `build.sh` (Info.plist keys). This is the first tab so it's the default view
/// when the Settings window opens.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Self Driving Wiki")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(GeneratedVersion.fullVersionString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Form {
                Section {
                    LabeledContent("Version", value: GeneratedVersion.appVersion)
                    LabeledContent("Build", value: GeneratedVersion.buildVersion)
                    LabeledContent("Git SHA", value: GeneratedVersion.gitSHA)
                    LabeledContent("Commit", value: GeneratedVersion.gitCommitCount)
                }
            }
            .formStyle(.grouped)
            .disabled(true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    AboutView()
        .frame(width: 460, height: 460)
}

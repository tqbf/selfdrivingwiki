import Foundation
import Testing

@Suite("App transport security packaging")
struct AppTransportSecurityPackagingTests {
    @Test("main app permits user-selected HTTP URLs without changing helper policies")
    func mainAppPermitsUserSelectedHTTPURLs() throws {
        let buildScript = try String(
            contentsOf: Self.repositoryRoot.appending(path: "build.sh"),
            encoding: .utf8)

        let mainAppPlist = try #require(Self.heredocBody(
            in: buildScript,
            introducedBy: "cat > \"${CONTENTS}/Info.plist\" <<PLIST"))
        let fileProviderPlist = try #require(Self.heredocBody(
            in: buildScript,
            introducedBy: "cat > \"${APPEX_CONTENTS}/Info.plist\" <<PLIST"))
        let daemonPlist = try #require(Self.heredocBody(
            in: buildScript,
            introducedBy: "cat > \"${DAEMON_XPC_CONTENTS}/Info.plist\" <<PLIST"))

        #expect(mainAppPlist.contains("<key>NSAppTransportSecurity</key>"))
        #expect(mainAppPlist.contains("<key>NSAllowsArbitraryLoads</key><true/>"))
        #expect(!fileProviderPlist.contains("NSAppTransportSecurity"))
        #expect(!daemonPlist.contains("NSAppTransportSecurity"))
    }

    private static func heredocBody(in script: String, introducedBy marker: String) -> Substring? {
        guard let markerRange = script.range(of: marker) else { return nil }
        let bodyStart = markerRange.upperBound
        guard let bodyEnd = script.range(of: "\nPLIST", range: bodyStart..<script.endIndex)?.lowerBound
        else { return nil }
        return script[bodyStart..<bodyEnd]
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

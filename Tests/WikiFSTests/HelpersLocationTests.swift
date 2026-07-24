import Foundation
import Testing
@testable import WikiFSCore

/// Regression tests for `HelpersLocation` bundle resolution.
///
/// The `wikid` daemon shipped as a bundled XPC service (#887), which changed
/// its `Bundle.main` from the app bundle to `…/App.app/Contents/XPCServices/
/// wikid.xpc`. A naive `Bundle.main.bundleURL/Contents/Helpers` then resolved
/// to `wikid.xpc/Contents/Helpers` — where `build.sh` copies NO helpers — so
/// bun/wikictl were unresolvable in the daemon and ACP ingestion failed with
/// "‘bun’ was not found on your PATH". `enclosingAppBundleURL(from:)` walks up
/// to the enclosing `.app` so nested bundles share the app-level Helpers dir.
struct HelpersLocationTests {

    @Test func enclosingApp_fromXPCService_walksUpToApp() {
        // The exact nesting the XPC-service migration introduced.
        let xpc = URL(fileURLWithPath:
            "/Applications/Self Driving Wiki.app/Contents/XPCServices/wikid.xpc")
        let app = HelpersLocation.enclosingAppBundleURL(from: xpc)
        #expect(app?.path == "/Applications/Self Driving Wiki.app")
    }

    @Test func enclosingApp_fromAppBundle_returnsItself() {
        // The main app process: Bundle.main IS the .app — behavior unchanged.
        let app = URL(fileURLWithPath: "/Applications/Self Driving Wiki.app")
        #expect(HelpersLocation.enclosingAppBundleURL(from: app)?.path
                == "/Applications/Self Driving Wiki.app")
    }

    @Test func enclosingApp_fromAppExtension_walksUpToApp() {
        // The File Provider extension nests one level deeper under PlugIns.
        let appex = URL(fileURLWithPath:
            "/Applications/Self Driving Wiki.app/Contents/PlugIns/WikiFSFileProvider.appex")
        #expect(HelpersLocation.enclosingAppBundleURL(from: appex)?.path
                == "/Applications/Self Driving Wiki.app")
    }

    @Test func enclosingApp_fromDevBuildDir_returnsNil() {
        // `swift run` from `.build/debug/` has no `.app` ancestor — the caller
        // falls back to Bundle.main / the executable-dir candidate.
        let dev = URL(fileURLWithPath:
            "/Users/dev/project/.build/debug")
        #expect(HelpersLocation.enclosingAppBundleURL(from: dev) == nil)
    }
}

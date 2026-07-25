import Foundation
import Testing
@testable import WikiFSCore

/// Regression tests for `WikiIdentifiers`' enclosing-app sidecar resolution.
///
/// The `wikid` daemon is a bundled XPC service whose executable lives at
/// `App.app/Contents/XPCServices/wikid.xpc/Contents/MacOS/wikid` — four levels
/// below `App.app/Contents/Resources`, where `build.sh` writes the
/// `wiki-identifiers.env` id sidecar. With only the two exe-relative candidates
/// the daemon found no sidecar and (a nested XPC service's Bundle.main Info.plist
/// custom keys not surfacing reliably) fell through to the
/// `group.org.sockpuppet.wiki` default → wrong App Group container → "No store
/// for wikiID" at ingest. `enclosingAppResourcesDirectory(from:)` walks up to the
/// enclosing `.app` so the daemon reads the app-level sidecar. #887 follow-up.
struct WikiIdentifiersSidecarTests {

    @Test func daemonExe_resolvesEnclosingAppResources() {
        let exe = URL(fileURLWithPath:
            "/Applications/Self Driving Wiki.app/Contents/XPCServices/wikid.xpc/Contents/MacOS")
        let res = WikiIdentifiers.enclosingAppResourcesDirectory(from: exe)
        #expect(res?.path == "/Applications/Self Driving Wiki.app/Contents/Resources")
    }

    @Test func appExe_resolvesOwnResources() {
        let exe = URL(fileURLWithPath:
            "/Applications/Self Driving Wiki.app/Contents/MacOS")
        let res = WikiIdentifiers.enclosingAppResourcesDirectory(from: exe)
        #expect(res?.path == "/Applications/Self Driving Wiki.app/Contents/Resources")
    }

    @Test func appexExe_resolvesEnclosingAppResources() {
        let exe = URL(fileURLWithPath:
            "/Applications/Self Driving Wiki.app/Contents/PlugIns/WikiFSFileProvider.appex/Contents/MacOS")
        let res = WikiIdentifiers.enclosingAppResourcesDirectory(from: exe)
        #expect(res?.path == "/Applications/Self Driving Wiki.app/Contents/Resources")
    }

    @Test func devBuildExe_returnsNil() {
        // `swift run` / `.build/debug/wikid` — no `.app` ancestor.
        let exe = URL(fileURLWithPath: "/Users/dev/project/.build/debug")
        #expect(WikiIdentifiers.enclosingAppResourcesDirectory(from: exe) == nil)
    }
}

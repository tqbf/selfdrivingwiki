import Foundation
import WebKit

/// Opt-in Web Inspector support for the app's webviews.
///
/// Enable with either:
/// - the launch environment `WIKIFS_WEBINSPECTOR=1`, or
/// - the user default `WIKIFS_WEBINSPECTOR = 1`
///   (`defaults write com.selfdrivingwiki.WikiFS WIKIFS_WEBINSPECTOR -bool true`,
///   or a toggle in Settings → Debug once one exists).
///
/// When enabled, every app webview becomes inspectable from Safari's
/// Develop menu: frame console messages, DOM state, and bridge postMessage
/// traffic are all visible.
enum DebugInspector {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WIKIFS_WEBINSPECTOR"] == "1"
            || UserDefaults.standard.bool(forKey: "WIKIFS_WEBINSPECTOR")
    }

    /// Apply to a configuration BEFORE the webview is created
    /// (developerExtrasEnabled is a WKPreferences KVC key).
    @MainActor
    static func apply(to configuration: WKWebViewConfiguration) {
        guard isEnabled else { return }
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    /// Apply to a view AFTER creation (isInspectable is a view property).
    @MainActor
    static func apply(to view: WKWebView) {
        guard isEnabled else { return }
        view.isInspectable = true
    }
}

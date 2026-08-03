import Foundation

/// File Provider extensions are discovered reliably only from an installed app.
/// Keep the rule pure/testable; the SwiftUI app decides how loudly to present it.
public enum AppInstallationPolicy {
  public static let expectedAppPath = "/Applications/Self Driving Wiki.app"

  public static func isExpectedInstallLocation(
    bundlePath: String,
    expectedPath: String = Self.expectedAppPath
  ) -> Bool {
    standardizedPath(bundlePath) == standardizedPath(expectedPath)
  }

  private static func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}

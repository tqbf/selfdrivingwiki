import Testing
@testable import WikiFSCore

@Suite struct AppInstallationPolicyTests {
  @Test func acceptsTheApplicationsInstallPath() {
    #expect(AppInstallationPolicy.isExpectedInstallLocation(
      bundlePath: "/Applications/Self Driving Wiki.app"))
  }

  @Test func rejectsBuildProductsWithTheSameBundleIdentifier() {
    #expect(!AppInstallationPolicy.isExpectedInstallLocation(
      bundlePath: "/Users/me/code/wikibot3000/build/Self Driving Wiki.app"))
  }

  @Test func standardizesEquivalentApplicationsPaths() {
    #expect(AppInstallationPolicy.isExpectedInstallLocation(
      bundlePath: "/Applications/../Applications/Self Driving Wiki.app"))
  }
}

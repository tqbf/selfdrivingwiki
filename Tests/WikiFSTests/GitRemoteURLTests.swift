import Foundation
import Testing

@testable import WikiFSCore

/// Locks the "Track a Repository" sheet's input contract: what we accept as a git
/// remote, what we hand `git clone`, and the `owner/repo` name we derive.
struct GitRemoteURLTests {

  // MARK: - Accepted forms

  @Test func parsesHTTPSRemote() {
    let parsed = GitRemoteURL.parse("https://github.com/jvanderberg/wikimemory")
    #expect(parsed?.remote == "https://github.com/jvanderberg/wikimemory")
    #expect(parsed?.name == "jvanderberg/wikimemory")
  }

  @Test func stripsDotGitFromTheNameButNotTheRemote() {
    // `.git` is fine for git and dropping it would change what we clone; it is
    // only noise in the display name.
    let parsed = GitRemoteURL.parse("https://github.com/owner/repo.git")
    #expect(parsed?.remote == "https://github.com/owner/repo.git")
    #expect(parsed?.name == "owner/repo")
  }

  @Test func dropsTrailingSlash() {
    let parsed = GitRemoteURL.parse("https://github.com/owner/repo/")
    #expect(parsed?.remote == "https://github.com/owner/repo")
    #expect(parsed?.name == "owner/repo")
  }

  @Test func upgradesSchemelessHostToHTTPS() {
    let parsed = GitRemoteURL.parse("github.com/owner/repo")
    #expect(parsed?.remote == "https://github.com/owner/repo")
    #expect(parsed?.name == "owner/repo")
  }

  @Test func leavesHTTPAlone() {
    // NOT upgraded to https: an internal git host may not serve https, and a
    // silent rewrite would fail confusingly at clone time.
    let parsed = GitRemoteURL.parse("http://git.internal/team/tools")
    #expect(parsed?.remote == "http://git.internal/team/tools")
    #expect(parsed?.name == "team/tools")
  }

  @Test func passesSCPFormThroughVerbatim() {
    // git's own parser owns this shape, and rewriting it would break ssh config
    // host aliases.
    let parsed = GitRemoteURL.parse("git@github.com:owner/repo.git")
    #expect(parsed?.remote == "git@github.com:owner/repo.git")
    #expect(parsed?.name == "owner/repo")
  }

  @Test func parsesSSHURL() {
    let parsed = GitRemoteURL.parse("ssh://git@github.com/owner/repo.git")
    #expect(parsed?.remote == "ssh://git@github.com/owner/repo.git")
    #expect(parsed?.name == "owner/repo")
  }

  @Test func trimsSurroundingWhitespace() {
    let parsed = GitRemoteURL.parse("  https://github.com/owner/repo\n")
    #expect(parsed?.remote == "https://github.com/owner/repo")
  }

  @Test func namesUseTheLastTwoSegments() {
    let parsed = GitRemoteURL.parse("https://gitlab.com/group/subgroup/project")
    #expect(parsed?.name == "subgroup/project")
  }

  // MARK: - Rejected forms

  @Test func rejectsEmptyAndNonRemoteInput() {
    #expect(GitRemoteURL.parse("") == nil)
    #expect(GitRemoteURL.parse("   ") == nil)
    #expect(GitRemoteURL.parse("not a url") == nil)
  }

  @Test func rejectsUnsupportedSchemes() {
    #expect(GitRemoteURL.parse("ftp://example.com/repo") == nil)
    #expect(GitRemoteURL.parse("file:///Users/me/repo") == nil)
  }

  @Test func rejectsAHostWithNoPath() {
    // Nothing to name, and nothing meaningful to clone.
    #expect(GitRemoteURL.parse("https://github.com") == nil)
    #expect(GitRemoteURL.parse("https://github.com/") == nil)
  }
}

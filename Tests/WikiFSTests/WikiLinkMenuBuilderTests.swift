import Foundation
import Testing
import WikiFSCore

/// Unit tests for `WikiLinkMenuBuilder` — the pure, storage-free half of the
/// right-click link context menu. Covers which actions apply per link URL kind
/// (`actions(for:)`). The view layer in `WikiFS` maps these actions to menu
/// items with real closures.
struct WikiLinkMenuBuilderTests {

  private func url(_ s: String) -> URL {
    guard let url = URL(string: s) else {
      Issue.record("bad test URL: \(s)"); return URL(fileURLWithPath: "/")
    }
    return url
  }

  // MARK: - actions(for:)

  @Test func resolvedPageTopActionsAreBackgroundTabCopyPathDownload() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Foo"))
        == [.openInBackgroundTab, .copyFilePath, .downloadLink])
  }

  @Test func resolvedSourceTopActionsAreBackgroundTabCopyPathDownload() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://source?title=Bar"))
        == [.openInBackgroundTab, .copyFilePath, .downloadLink])
  }

  @Test func resolvedPageBottomActionsAreFindSimilar() {
    #expect(WikiLinkMenuBuilder.bottomActions(for: url("wiki://page?title=Foo")) == [.findSimilar])
  }

  @Test func resolvedSourceBottomActionsAreFindSimilar() {
    #expect(WikiLinkMenuBuilder.bottomActions(for: url("wiki://source?title=Bar")) == [.findSimilar])
  }

  @Test func missingLinkHasNoBottomActions() {
    #expect(WikiLinkMenuBuilder.bottomActions(for: url("wiki://missing?title=Baz")) == [])
  }

  @Test func externalLinkHasNoBottomActions() {
    #expect(WikiLinkMenuBuilder.bottomActions(for: url("https://example.com")) == [])
  }

  @Test func missingLinkGetsSuggestOnly() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://missing?title=Baz"))
        == [.suggest])
  }

  @Test func samePageAnchorHasNoActions() {
    #expect(WikiLinkMenuBuilder.actions(for: url("wiki://anchor#Section")) == [])
  }

  @Test func externalHttpsGetsAddSourceBrowserDownloadAndCopy() {
    // http(s) links lead with "Add as Source" (fetch + ingest), then browser/download/copy.
    #expect(
      WikiLinkMenuBuilder.actions(for: url("https://github.com/foo/bar"))
        == [.addAsSource, .openInBrowser, .downloadLink, .copyLink])
  }

  @Test func externalHttpGetsAddSourceBrowserDownloadAndCopy() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("http://example.com/page"))
        == [.addAsSource, .openInBrowser, .downloadLink, .copyLink])
  }

  @Test func externalMailtoGetsBrowserAndCopy() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("mailto:user@example.com"))
        == [.openInBrowser, .copyLink])
  }

  @Test func pageLinkWithFragmentStillResolved() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Foo#Section"))
        == [.openInBackgroundTab, .copyFilePath, .downloadLink])
  }

  @Test func encodedTitleIsAccepted() {
    // "Baz Q" percent-encoded in the query value still classifies as a page link.
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Baz%20Q"))
        == [.openInBackgroundTab, .copyFilePath, .downloadLink])
  }
}

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

  @Test func resolvedPageTopActionsAreAddBookmark() {
    // openInBackgroundTab is handled directly in willOpenMenu so it sits
    // below WebKit's "Open Link"; copyFilePath and downloadLink are removed
    // (Share replaces both). Resolved links offer "Add Bookmark…" (#188).
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Foo"))
        == [.addBookmark])
  }

  @Test func resolvedSourceTopActionsAreAddBookmark() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://source?title=Bar"))
        == [.addBookmark])
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

  @Test func externalHttpsGetsAddAsSourceOnly() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("https://github.com/foo/bar"))
        == [.addAsSource])
  }

  @Test func externalHttpGetsAddAsSourceOnly() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("http://example.com/page"))
        == [.addAsSource])
  }

  @Test func externalMailtoHasNoActions() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("mailto:user@example.com"))
        == [])
  }

  @Test func pageLinkWithFragmentStillResolved() {
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Foo#Section"))
        == [.addBookmark])
  }

  @Test func encodedTitleIsAccepted() {
    // "Baz Q" percent-encoded in the query value still classifies as a page link.
    #expect(
      WikiLinkMenuBuilder.actions(for: url("wiki://page?title=Baz%20Q"))
        == [.addBookmark])
  }
}

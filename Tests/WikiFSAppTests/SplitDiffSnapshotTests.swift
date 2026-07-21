#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Not assertion tests — a visual harness. Hosts the real compare surfaces in a
/// dark window, lets async work settle, then writes PNGs so the redesigned diff
/// and chrome can be eyeballed (the "acceptance test is a screenshot" this
/// layout rework needs). A light structural assertion keeps them honest.
@Suite(.timeLimit(.minutes(5)))
@MainActor
struct SplitDiffSnapshotTests {

    /// Render an SwiftUI view hosted at `size` (dark appearance) to a PNG.
    private func snapshot<V: View>(_ view: V, size: CGSize, to name: String,
                                   settle: Int = 40) async throws -> Int {
        let root = ZStack {
            Color(nsColor: .windowBackgroundColor)
            view
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let hosting = NSHostingController(rootView: root)
        hosting.view.appearance = NSAppearance(named: .darkAqua)
        hosting.view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentViewController: hosting)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<settle { try await Task.sleep(for: .milliseconds(30)) }

        let content = try #require(window.contentView)
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let out = URL(fileURLWithPath: "/tmp/\(name).png")
        try png.write(to: out)
        print("SNAPSHOT_WRITTEN \(out.path) \(rep.pixelsWide)x\(rep.pixelsHigh) \(png.count)B")
        // Scale-independent: `bitmapImageRepForCachingDisplay` bakes in the
        // backing scale (2× Retina → 2×, 1×/headless → 1×), so assert on the
        // point-size lower bound, not a fixed pixel count.
        #expect(rep.pixelsWide >= Int(size.width))
        #expect(png.count > 10_000)
        return png.count
    }

    // MARK: - SplitDiffView in isolation

    @Test func renderDiffPaneToPNG() async throws {
        let left = SampleDiff.left, right = SampleDiff.right
        let view = SplitDiffView(leftLabel: "Legacy", rightLabel: "Unknown",
                                 left: left, right: right)
        _ = try await snapshot(view, size: CGSize(width: 1000, height: 640),
                               to: "split-diff-snapshot")
    }

    // MARK: - Full ExtractionCompareSheet (chrome + HSplitView context + nominate)

    @Test func renderFullSheetBothModesAndNominate() async throws {
        let store = try makeTwoBackendStore()
        let sourceID = store.sources.first { $0.filename.hasSuffix(".pdf") }!.id

        // Rendered mode (default): verifies toolbar Base/Compare pickers, sidebar
        // provenance rows with the Active badge + "Set Active", and pane headers.
        let rendered = ExtractionCompareSheet(store: store, sourceID: sourceID,
                                              filename: "Thinking+is+Believing.pdf")
        _ = try await snapshot(rendered, size: CGSize(width: 1100, height: 680),
                               to: "compare-sheet-rendered")

        // Diff mode inside the real HSplitView (the frame-propagation context the
        // isolation render can't see).
        let diff = ExtractionCompareSheet(store: store, sourceID: sourceID,
                                          filename: "Thinking+is+Believing.pdf",
                                          startInDiff: true)
        _ = try await snapshot(diff, size: CGSize(width: 1100, height: 680),
                               to: "compare-sheet-diff")

        // AC.3: nominate the non-active alternative, then re-render — the Active
        // badge must move. Drive the same model seam the sidebar button uses.
        let alts = store.processedMarkdownAlternatives(for: sourceID)
        let inactive = try #require(alts.first { !$0.isActive })
        store.setActiveMarkdown(for: sourceID, to: inactive.id)
        let after = store.processedMarkdownAlternatives(for: sourceID)
        #expect(after.first { $0.isActive }?.id == inactive.id)   // HEAD moved

        let renominated = ExtractionCompareSheet(store: store, sourceID: sourceID,
                                                 filename: "Thinking+is+Believing.pdf")
        _ = try await snapshot(renominated, size: CGSize(width: 1100, height: 680),
                               to: "compare-sheet-after-nominate")
    }

    // MARK: - Fixtures

    /// A store with one PDF source carrying two extraction alternatives
    /// (anthropic + gemini), mirroring `ProcessedMarkdownTests`' setup.
    private func makeTwoBackendStore() throws -> WikiStoreModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-diff-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StoreBackend.current.makeStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        let file = try store.addSource(filename: "Thinking+is+Believing.pdf",
                                       data: Data("%PDF-1.4".utf8))
        _ = try store.recordMarkdownExtraction(
            sourceID: file.id, content: SampleDiff.left,
            backend: .anthropic, sourceVersionID: nil, note: nil,
            modelVersion: "claude-opus-4")
        usleep(2000)
        _ = try store.recordMarkdownExtraction(
            sourceID: file.id, content: SampleDiff.right,
            backend: .gemini, sourceVersionID: nil, note: nil,
            modelVersion: "gemini-2.0")
        return WikiStoreModel(store: store)
    }
}

private enum SampleDiff {
    static let left = """
    # Thinking is Believing

    This article was downloaded by: [Baruch College Library]
    On: 06 March 2014, At: 13:04
    Publisher: Routledge

    ## Introduction

    The received view holds that belief is passive.
    We take in the world and it prints itself upon us.
    This paper argues the opposite: thinking is believing.

    Consider the case of the distracted reader.
    She scans the page but retains nothing.
    Her eyes move; her mind does not commit.

    The conclusion follows directly.
    """

    static let right = """
    # Thinking is Believing

    Inquiry: An Interdisciplinary Journal of Philosophy
    Publisher: Routledge

    ## Introduction

    The received view holds that belief is passive.
    We take in the world and it prints itself upon us.
    This paper argues the opposite: thinking is believing.
    Belief, on this account, is an act rather than a reception.

    Consider the case of the distracted reader.
    She scans the page but retains nothing at all.
    Her eyes move; her mind does not commit.

    The conclusion follows directly, and it is this.
    """
}
#endif

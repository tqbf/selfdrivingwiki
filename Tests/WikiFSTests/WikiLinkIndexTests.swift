import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for the shared `WikiLinkIndex` builder (#511).
/// The builder is a pure function over pre-fetched entries — no store access —
/// so these tests exercise it directly without a SQLite database.
struct WikiLinkIndexTests {

    // MARK: - Entry construction + pass-through

    @Test func entriesArePreservedInOrder() {
        let index = WikiLinkIndex.build(
            pages: [
                .init(id: "01AAA", title: "Home"),
                .init(id: "01BBB", title: "About"),
            ],
            sources: [
                .init(id: "01SRC", filename: "Paper.pdf", ext: "pdf",
                      mime: "application/pdf", displayName: "My Paper"),
            ],
            chats: [
                .init(id: "01CHT", title: "Discussion"),
            ],
            siblingImages: [:]
        )
        #expect(index.pages.count == 2)
        #expect(index.pages[0].title == "Home")
        #expect(index.pages[1].title == "About")
        #expect(index.sources.count == 1)
        #expect(index.sources[0].humanName == "My Paper")
        #expect(index.chats.count == 1)
        #expect(index.chats[0].title == "Discussion")
    }

    @Test func emptyInputsProduceEmptyIndex() {
        let index = WikiLinkIndex.build(
            pages: [], sources: [], chats: [], siblingImages: [:])
        #expect(index.pages.isEmpty)
        #expect(index.sources.isEmpty)
        #expect(index.chats.isEmpty)
        #expect(index.sourceLowerNameVariants.isEmpty)
        #expect(index.sourceByLooseKey.isEmpty)
        #expect(index.chatByLooseKey.isEmpty)
        #expect(index.siblingImages.isEmpty)
        #expect(index.uniqueSourceLooseKeys.isEmpty)
    }

    @Test func siblingImagesArePassedThrough() {
        let sib: [PageID: [String: PageID]] = [
            PageID(rawValue: "01SRC"): ["img/photo.jpg": PageID(rawValue: "02SIB")]
        ]
        let index = WikiLinkIndex.build(
            pages: [], sources: [], chats: [], siblingImages: sib)
        #expect(index.siblingImages == sib)
    }

    // MARK: - Source name variants

    @Test func sourceNameVariantsIncludeDisplayNameFilenameAndExtStripped() {
        let index = WikiLinkIndex.build(
            pages: [],
            sources: [
                .init(id: "01", filename: "Paper.pdf", ext: "pdf",
                      mime: "application/pdf", displayName: "My Paper"),
            ],
            chats: [],
            siblingImages: [:])
        // displayName "My Paper" → lowercased "my paper"
        #expect(index.sourceLowerNameVariants.contains("my paper"))
        // filename "Paper.pdf" → lowercased "paper.pdf" + ext-stripped "paper"
        #expect(index.sourceLowerNameVariants.contains("paper.pdf"))
        #expect(index.sourceLowerNameVariants.contains("paper"))
    }

    @Test func sourceNameVariantsWhenDisplayNameIsNil() {
        let index = WikiLinkIndex.build(
            pages: [],
            sources: [
                .init(id: "01", filename: "Doc.txt", ext: "txt",
                      mime: "text/plain", displayName: nil),
            ],
            chats: [],
            siblingImages: [:])
        // Only filename "Doc.txt" → "doc.txt" + ext-stripped "doc"
        // No displayName variants (nil is skipped by compactMap)
        #expect(index.sourceLowerNameVariants.contains("doc.txt"))
        #expect(index.sourceLowerNameVariants.contains("doc"))
        #expect(!index.sourceLowerNameVariants.contains("doc.txt".uppercased()))
    }

    // MARK: - Loose-key maps (sources)

    @Test func uniqueSourceLooseKeyIsIncluded() {
        let index = WikiLinkIndex.build(
            pages: [],
            sources: [
                .init(id: "01", filename: "Unique Paper.pdf", ext: "pdf",
                      mime: nil, displayName: nil),
            ],
            chats: [],
            siblingImages: [:])
        let key = WikiNameRules.looseMatchKey("Unique Paper.pdf")
        #expect(index.sourceByLooseKey[key] == "Unique Paper.pdf")
        #expect(index.uniqueSourceLooseKeys.contains(key))
    }

    @Test func collidingSourceLooseKeysAreOmitted() {
        // Two sources whose loose keys collide (different names, same loose key).
        let index = WikiLinkIndex.build(
            pages: [],
            sources: [
                .init(id: "01", filename: "Paper.pdf", ext: "pdf",
                      mime: nil, displayName: "Some Paper (2020)"),
                .init(id: "02", filename: "paper.docx", ext: "docx",
                      mime: nil, displayName: "Some Paper (2021)"),
            ],
            chats: [],
            siblingImages: [:])
        // Both names normalize to the same loose key → collision → omitted.
        let key = WikiNameRules.looseMatchKey("Some Paper (2020)")
        #expect(index.sourceByLooseKey[key] == nil)
        #expect(!index.uniqueSourceLooseKeys.contains(key))
    }

    @Test func uniqueSourceLooseKeysEqualsSourceByLooseKeyKeys() {
        // The unique set is, by construction, the keys of the collision-free map.
        let index = WikiLinkIndex.build(
            pages: [],
            sources: [
                .init(id: "01", filename: "Alpha.pdf", ext: "pdf",
                      mime: nil, displayName: nil),
                .init(id: "02", filename: "Beta.md", ext: "md",
                      mime: nil, displayName: nil),
                .init(id: "03", filename: "Gamma.txt", ext: "txt",
                      mime: nil, displayName: nil),
            ],
            chats: [],
            siblingImages: [:])
        #expect(index.uniqueSourceLooseKeys == Set(index.sourceByLooseKey.keys))
    }

    // MARK: - Loose-key maps (chats)

    @Test func uniqueChatLooseKeyIsIncluded() {
        let index = WikiLinkIndex.build(
            pages: [], sources: [],
            chats: [.init(id: "01", title: "My Discussion")],
            siblingImages: [:])
        let key = WikiNameRules.looseMatchKey("My Discussion")
        #expect(index.chatByLooseKey[key] == "My Discussion")
    }

    @Test func collidingChatLooseKeysAreOmitted() {
        let index = WikiLinkIndex.build(
            pages: [], sources: [],
            chats: [
                .init(id: "01", title: "Talk (2026)"),
                .init(id: "02", title: "Talk (2025)"),
            ],
            siblingImages: [:])
        let key = WikiNameRules.looseMatchKey("Talk (2026)")
        #expect(index.chatByLooseKey[key] == nil)
    }

    // MARK: - Consistency with WRC and Projection shapes

    @Test func sourceByLooseKeyValuesAreHumanNames() {
        // The loose-key map values must be humanNames so the Projection adapter
        // can look up the Target via sourceByName[humanName].
        let index = WikiLinkIndex.build(
            pages: [],
            sources: [
                .init(id: "01", filename: "file.pdf", ext: "pdf",
                      mime: nil, displayName: "Display Name"),
            ],
            chats: [],
            siblingImages: [:])
        let key = WikiNameRules.looseMatchKey("Display Name")
        #expect(index.sourceByLooseKey[key] == "Display Name")
        // humanName is displayName when non-nil, not filename
        #expect(index.sourceByLooseKey[key] != "file.pdf")
    }

    @Test func chatByLooseKeyValuesAreTitles() {
        let index = WikiLinkIndex.build(
            pages: [], sources: [],
            chats: [.init(id: "01", title: "Chat Title")],
            siblingImages: [:])
        let key = WikiNameRules.looseMatchKey("Chat Title")
        #expect(index.chatByLooseKey[key] == "Chat Title")
    }
}

import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

struct MetadataValueRendererTests {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let calendar = Calendar(identifier: .gregorian)

    @Test func rendersText() {
        #expect(render(.text("value")) == .text("value", usesTabularDigits: false))
    }

    @Test func rendersDate() {
        if case .text(let value, _) = render(.date(Date(timeIntervalSince1970: 0))) {
            // Second precision: runs seconds apart must stay distinguishable.
            // The time portion must be h:mm:ss ("4:00:00 PM"), not the
            // minute-only h:mm ("4:00 PM"). Epoch 0 renders in the machine's
            // timezone, so match the shape, not a literal time.
            #expect(value.range(of: #"\d{1,2}:\d{2}:\d{2}"#, options: .regularExpression) != nil)
        } else { Issue.record("date must render as text") }
    }

    @Test func rendersByteCount() {
        #expect(render(.byteCount(1024)).usesTabularDigits)
    }

    @Test func rendersInteger() {
        #expect(render(.integer(12)).usesTabularDigits)
    }

    @Test func rendersTokenCount() {
        #expect(render(.tokenCount(12)).usesTabularDigits)
    }

    @Test func rendersDuration() {
        #expect(render(.duration(.seconds(61))).usesTabularDigits)
    }

    @Test func rendersIdentifier() {
        #expect(render(.identifier("id")) == .identifier("id"))
    }

    @Test func rendersLink() {
        let target = MetadataLinkTarget.page(PageID(rawValue: "page"))
        #expect(render(.link(label: "Page", target: target)) == .link(label: "Page", target: target))
    }

    @Test func rendersAction() {
        let target = MetadataActionTarget.comparePageVersions(PageID(rawValue: "page"))
        #expect(render(.action(label: "Compare", target: target)) == .action(label: "Compare", target: target))
    }

    @Test func usesTabularDigitsForCounts() {
        #expect(render(.integer(1)).usesTabularDigits)
        #expect(!render(.text("1")).usesTabularDigits)
    }

    private func render(_ value: MetadataValue) -> MetadataValueRenderer.Presentation {
        MetadataValueRenderer.presentation(for: value, locale: locale, calendar: calendar)
    }
}

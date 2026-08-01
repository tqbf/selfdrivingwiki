import SwiftUI
import Testing
@testable import WikiFS

struct InspectorTabTests {
    @Test func pageTabsStartWithMetadata() {
        #expect(InspectorTab.pageAvailableTabs == [.metadata, .outline, .history])
    }

    @Test func sourceTabsStartWithMetadata() {
        #expect(InspectorTab.sourceAvailableTabs(hasOutline: true) == [.metadata, .outline, .history])
        #expect(InspectorTab.sourceAvailableTabs(hasOutline: false) == [.metadata, .history])
    }

    @Test func chatTabsStartWithMetadata() {
        #expect(InspectorTab.persistedChatAvailableTabs == [.metadata, .outline])
    }

    @Test func metadataOnlyHidesPicker() {
        #expect(InspectorTab.metadataOnlyAvailableTabs == [.metadata])
    }

    @Test @MainActor func registrationCarriesOrderedTabsNotBooleans() {
        let registration = RightSidebarRegistration(
            inspectorTab: .constant(.metadata), outlineWidth: .constant(220),
            availableTabs: [.metadata, .history], metadataState: .idle,
            origin: nil, history: [], onOpenChat: { _ in }, onCompareVersions: nil,
            metadataRouter: .init(openPage: { _ in true }, openSource: { _ in true }, openChat: { _ in true }, selectActivity: { _ in true }, comparePageVersions: { _ in true }, compareSourceExtractions: { _ in true }, copy: { _ in true }, openURL: { _ in true }),
            outline: { AnyView(EmptyView()) })
        #expect(registration.availableTabs == [InspectorTab.metadata, .history])
    }
    @Test func legacyOutlineDecodes() {
        #expect(InspectorTab.decodePersisted("outline") == .outline)
    }

    @Test func legacyHistoryDecodes() {
        #expect(InspectorTab.decodePersisted("history") == .history)
    }

    @Test func unknownValueDecodesAsMetadata() {
        #expect(InspectorTab.decodePersisted("future") == .metadata)
        #expect(InspectorTab.decodePersisted("") == .metadata)
        #expect(InspectorTab.decodePersisted(nil) == .metadata)
    }

    @Test func normalizationKeepsAvailableSelection() {
        #expect(InspectorTab.normalizedFallback(selection: .history, availableTabs: [.metadata, .history]) == .history)
    }

    @Test func normalizationFallsBackToMetadata() {
        #expect(InspectorTab.normalizedFallback(selection: .outline, availableTabs: [.metadata, .history]) == .metadata)
    }

    @Test func normalizationFallsBackToFirstWithoutMetadata() {
        #expect(InspectorTab.normalizedFallback(selection: .metadata, availableTabs: [.history]) == .history)
    }

    @Test func emptyTabsReportsProgrammerErrorExactlyOnce() {
        var reports = 0
        let result = InspectorTab.normalize(selection: .outline, availableTabs: []) { reports += 1 }
        #expect(reports == 1)
        #expect(result == .metadata)
    }

    @Test func emptyTabsPureFallbackReturnsMetadataWhenReporterReturns() {
        #expect(InspectorTab.normalizedFallback(selection: .history, availableTabs: []) == .metadata)
    }

    @Test func nonEmptyTabsDoNotReportProgrammerError() {
        var reports = 0
        _ = InspectorTab.normalize(selection: .outline, availableTabs: [.metadata, .outline]) { reports += 1 }
        #expect(reports == 0)
    }
}

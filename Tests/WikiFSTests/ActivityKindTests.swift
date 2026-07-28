import Testing
@testable import WikiFSTypes

@Suite struct ActivityKindTests {
    @Test("known activity kinds round-trip")
    func knownKindsRoundTrip() {
        #expect(ActivityKind(rawValue: ActivityKind.import.rawValue) == .import)
        #expect(ActivityKind(rawValue: ActivityKind.edit.rawValue) == .edit)
    }

    @Test("unknown activity kinds are preserved")
    func preservesUnknownKinds() {
        let value = "extract"
        #expect(ActivityKind(rawValue: value) == .other(value))
        #expect(ActivityKind.other(value).rawValue == value)
    }

    @Test("missing activity kind falls back to import")
    func nilFallsBackToImport() {
        #expect(ActivityKind(rawValue: nil) == .import)
    }
}

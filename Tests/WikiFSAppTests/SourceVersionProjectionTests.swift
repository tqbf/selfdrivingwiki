import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

struct SourceVersionProjectionTests {

    @Test func sourceOriginProvenanceEntryPreservesRawSourceVersionString() {
        let versionID = SourceVersionID(rawValue: "01JPROVENANCESOURCEVERSION0001")
        let origin = SourceOrigin(
            versionID: versionID,
            agentName: "website",
            agentKind: "software",
            activityKind: "fetch",
            plan: "https://example.com/provenance",
            externalRef: "https://example.com/provenance",
            externalIdentity: "https://example.com/provenance",
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(origin.provenanceEntry.versionID == .source(versionID))
        #expect(origin.provenanceEntry.versionID.rawValue == versionID.rawValue)
    }
}

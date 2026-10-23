import Foundation
import WikiFSTypes
import WikiFSMarkdown

/// One immutable page snapshot for a lint run (REQ-14): page identity, exact
/// title, the inspected head version, a body fingerprint, the exact body
/// bytes, and the head's recorded source inputs — all captured from one
/// coherent store read so the audit and any repair compose against exactly
/// these bytes.
public struct LintPageSnapshot: Equatable, Sendable {
    public let pageID: PageID
    public let title: String
    /// The inspected head version; `nil` for a page with no version rows.
    public let headVersionID: PageVersionID?
    /// SHA-256 hex of the body's UTF-8 bytes — the write-path receipt key.
    public let bodyFingerprint: String
    /// The exact body bytes under audit.
    public let body: String
    /// The head version's recorded source inputs (the provenance a repair
    /// must carry forward).
    public let sourceInputs: [PageVersionSourceInput]

    public init(
        pageID: PageID,
        title: String,
        headVersionID: PageVersionID?,
        body: String,
        sourceInputs: [PageVersionSourceInput]
    ) {
        self.pageID = pageID
        self.title = title
        self.headVersionID = headVersionID
        self.body = body
        self.bodyFingerprint = Self.fingerprint(of: body)
        self.sourceInputs = sourceInputs
    }

    /// SHA-256 hex over the body's UTF-8 bytes.
    public static func fingerprint(of body: String) -> String {
        RendererSHA256.digest(Data(body.utf8)).hex
    }

    /// Capture a snapshot from one coherent store read.
    public init(_ read: PageCoherentRead) {
        self.init(
            pageID: read.id,
            title: read.title,
            headVersionID: read.headVersionID,
            body: read.body,
            sourceInputs: read.headSourceInputs)
    }
}

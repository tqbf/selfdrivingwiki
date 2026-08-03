// pattern: Functional Core

import Foundation

/// The transcript's local follow policy. It deliberately has no view or WebKit
/// dependency so scrolling behavior can be characterized without a hosted view.
enum ChatTranscriptFollowState: Equatable, Sendable {
    /// New streaming content may move the viewport only while the reader is at
    /// the end of the transcript.
    case following
    /// The reader intentionally moved away from the end. Content may update,
    /// but it must not move selection, focus, or the reading anchor.
    case readingHistory

    enum Event: Equatable, Sendable {
        case viewportChanged(distanceFromBottom: Double)
        case transcriptReset
    }

    static func reducing(_ state: Self, event: Event) -> Self {
        switch event {
        case .transcriptReset:
            .following
        case .viewportChanged(let distanceFromBottom):
            distanceFromBottom <= ChatTranscriptFollowMetrics.nearBottomDistance
                ? .following
                : .readingHistory
        }
    }

    var followsStreamingContent: Bool {
        self == .following
    }
}

enum ChatTranscriptFollowMetrics {
    /// Points from the bottom that still count as following. Named here rather
    /// than repeated in JavaScript and Swift so tuning has one semantic owner.
    static let nearBottomDistance = 72.0
}

enum ChatTranscriptPresentationMetrics {
    static let reasoningPreviewLength = 80
}

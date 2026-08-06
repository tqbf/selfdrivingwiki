import Foundation

// pattern: Functional Core

/// The only renderer-host failures that can disable installed renderer code.
/// Validation, input limits, user close, host cancellation, authorization, and
/// policy rejection intentionally have no case here and cannot be counted.
public enum RendererInstalledRendererFailureCause: String, Codable, CaseIterable, Hashable, Sendable {
    case loadTimedOut
    case entryNavigationFailed
    case bridgeBootstrapFailed
    case webContentProcessTerminated
}

/// Named failure-window policy for the machine-wide installed-renderer kill switch.
public enum RendererInstalledRendererFailurePolicy {
    public static let threshold = 3
    public static let window: TimeInterval = 10 * 60
    /// Keeps the durable, content-free accounting record bounded even when
    /// many installed versions fail during one window.
    public static let maximumRetainedFailures = 128
}

/// One persisted qualifying failure for one immutable installed package version.
public struct RendererInstalledRendererFailure: Codable, Hashable, Sendable {
    public let packageID: RendererPackageID
    public let version: RendererPackageVersion
    public let cause: RendererInstalledRendererFailureCause
    public let occurredAt: RFC3339Timestamp

    public init(
        packageID: RendererPackageID,
        version: RendererPackageVersion,
        cause: RendererInstalledRendererFailureCause,
        occurredAt: RFC3339Timestamp
    ) {
        self.packageID = packageID
        self.version = version
        self.cause = cause
        self.occurredAt = occurredAt
    }

    var reservation: RendererPackageReservation {
        .init(packageID: packageID, version: version)
    }
}

public struct RendererInstalledRendererFailureWindow: Equatable, Sendable {
    public let count: Int
    public let hasReachedThreshold: Bool

    init(count: Int) {
        self.count = count
        hasReachedThreshold = count >= RendererInstalledRendererFailurePolicy.threshold
    }
}

func rendererInstalledRendererFailuresPruned(
    _ failures: [RendererInstalledRendererFailure],
    now: Date
) throws -> [RendererInstalledRendererFailure] {
    let earliestIncluded = now.addingTimeInterval(-RendererInstalledRendererFailurePolicy.window)
    let current = try failures.filter { try $0.occurredAt.date() >= earliestIncluded }
    return Array(current.suffix(RendererInstalledRendererFailurePolicy.maximumRetainedFailures))
}

func rendererInstalledRendererFailureWindow(
    _ failures: [RendererInstalledRendererFailure],
    reservation: RendererPackageReservation
) -> RendererInstalledRendererFailureWindow {
    .init(count: failures.count(where: { $0.reservation == reservation }))
}

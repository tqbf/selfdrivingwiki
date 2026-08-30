import Foundation

/// Formatting is kept pure so all metadata subjects render values consistently
/// and tests can exercise locale-sensitive output without hosting SwiftUI.
enum MetadataValueRenderer {
    enum Presentation: Equatable, Sendable {
        case text(String, usesTabularDigits: Bool)
        case identifier(String)
        case link(label: String, target: MetadataLinkTarget)
        case action(label: String, target: MetadataActionTarget)

        var usesTabularDigits: Bool {
            switch self {
            case .text(_, let usesTabularDigits): usesTabularDigits
            case .identifier, .link, .action: false
            }
        }
    }

    static func presentation(
        for value: MetadataValue,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> Presentation {
        switch value {
        case .text(let text): return .text(text, usesTabularDigits: false)
        case .date(let date):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateStyle = .medium
            // Seconds, not minutes: extraction runs seconds apart must be
            // distinguishable in the panel (two docx2md runs in one import
            // session looked identical at `.short` precision).
            formatter.timeStyle = .medium
            return .text(formatter.string(from: date), usesTabularDigits: false)
        case .byteCount(let count):
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = .useAll
            formatter.countStyle = .file
            return .text(formatter.string(fromByteCount: count), usesTabularDigits: true)
        case .integer(let integer), .tokenCount(let integer):
            return .text(integer.formatted(.number.locale(locale)), usesTabularDigits: true)
        case .duration(let duration):
            return .text(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)), usesTabularDigits: true)
        case .identifier(let identifier): return .identifier(identifier)
        case .link(let label, let target): return .link(label: label, target: target)
        case .action(let label, let target): return .action(label: label, target: target)
        }
    }
}

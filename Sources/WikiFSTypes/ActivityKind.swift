/// The kind of activity that produced a persisted version.
///
/// The raw value is the compatibility format used by the `activities.kind`
/// SQLite column. Unknown values are retained so newer writers can be read
/// without data loss by older clients.
public enum ActivityKind: Equatable, Hashable, Sendable {
    case `import`
    case edit
    case other(String)

    public var rawValue: String {
        switch self {
        case .import: return "import"
        case .edit: return "edit"
        case .other(let value): return value
        }
    }

    public init(rawValue value: String?) {
        switch value {
        case "import": self = .import
        case "edit": self = .edit
        case .some(let value): self = .other(value)
        case .none: self = .import
        }
    }
}

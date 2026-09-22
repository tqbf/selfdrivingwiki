import Foundation
import WikiFSTypes

/// The validated configuration of one sync declaration, loaded from the
/// declared config sidecar in the App Group container.
public struct ExtractorSyncSidecarValues: Sendable, Equatable {
    /// The declared non-list fields' trimmed string values, keyed by field
    /// name. Absent optional fields are simply missing.
    public let fieldValues: [String: String]
    /// The list field's item keys, in configured order.
    public let items: [String]

    public init(fieldValues: [String: String], items: [String]) {
        self.fieldValues = fieldValues
        self.items = items
    }
}

/// Typed sidecar failures with caller-facing messages — the message-quality
/// bar the retired per-package config errors set: name the value, name the
/// rule, never a bare decode failure.
public enum ExtractorSyncSidecarError: Error, Equatable, LocalizedError {
    /// A required field is absent (or the file is missing/corrupt, which
    /// loads as no values — the same fresh-install failure as before).
    case requiredFieldNotConfigured(field: String, configFileName: String)
    /// A required list field is present but empty — nothing to sync.
    case requiredListIsEmpty(field: String, configFileName: String)
    /// A declared field's value does not carry the declared shape.
    case invalidFieldValue(field: String, reason: String)
    /// The JSON value under a declared field is not a string (or the list
    /// is not an array of strings).
    case fieldValueNotAString(field: String)
    case listValueNotAnArray(field: String)
    case itemNotAString(field: String, index: Int)
    /// A list item violates the declared item validation.
    case invalidItem(item: String, reason: String)
    /// Duplicate list items hard-fail at load: the save-time contract the
    /// old per-package validation was written for, now enforced at sync
    /// load too (a deliberate strictness delta — the previous engine
    /// deduped silently in a second pass).
    case duplicateItem(item: String)
    /// The list exceeds the host's item cap.
    case tooManyItems(field: String, count: Int)

    public var errorDescription: String? {
        switch self {
        case .requiredFieldNotConfigured(let field, let configFileName):
            return "The \(field) value is not configured. Set it in \(configFileName) and sync again."
        case .requiredListIsEmpty(let field, let configFileName):
            return "No \(field) are configured. Add at least one item to \(configFileName) and sync again."
        case .invalidFieldValue(let field, let reason):
            return "The \(field) value is invalid: \(reason)."
        case .fieldValueNotAString(let field):
            return "The \(field) value must be a string."
        case .listValueNotAnArray(let field):
            return "The \(field) value must be a list of strings."
        case .itemNotAString(let field, let index):
            return "Item \(index) of \(field) must be a string."
        case .invalidItem(let item, let reason):
            return "The item \(item) is invalid: \(reason)."
        case .duplicateItem(let item):
            return "The item \(item) is listed more than once."
        case .tooManyItems(let field, let count):
            return "The \(field) list has \(count) items, above the supported maximum."
        }
    }
}

/// Loads one sync declaration's config sidecar. The declared fields are the
/// schema: unknown JSON keys are ignored (old files keep loading), required
/// fields and list items are validated against the declaration, and every
/// failure is typed with a caller-facing message.
///
/// Non-secret by construction — the API-key-shaped credentials a sync's
/// extraction needs live in Keychain behind the registration's credential
/// requirements, never in this file.
public enum ExtractorSyncSidecar {

    /// Loads and validates the declaration's config from `directory`.
    ///
    /// A missing or corrupt file loads as no values (same fresh-install
    /// degrade the per-package configs had), so validation surfaces the
    /// first required field as `requiredFieldNotConfigured` — callers never
    /// see a bare file error.
    public static func load(
        declaration: ExtractorSyncDeclaration,
        from directory: URL
    ) throws -> ExtractorSyncSidecarValues {
        let values = rawValues(declaration: declaration, from: directory)
        return try validated(declaration: declaration, raw: values)
    }

    /// The file's top-level object, or an empty object when the file is
    /// missing or corrupt. Values are raw JSON values; declared-field
    /// extraction happens in `validated`.
    private static func rawValues(
        declaration: ExtractorSyncDeclaration, from directory: URL
    ) -> [String: Any] {
        let url = directory.appendingPathComponent(
            declaration.configFileName, isDirectory: false)
        guard let data = DebugLog.trying("load", operation: { try Data(contentsOf: url) }) else {
            return [:]
        }
        guard let object = DebugLog.trying(
            "load decode", operation: {
                try JSONSerialization.jsonObject(with: data, options: [])
            }), let keyed = object as? [String: Any] else {
            DebugLog.config(
                "ExtractorSyncSidecar: corrupt \(declaration.configFileName), ignoring")
            return [:]
        }
        return keyed
    }

    /// Reads the declared fields out of the raw object and validates them
    /// against the declaration.
    private static func validated(
        declaration: ExtractorSyncDeclaration, raw: [String: Any]
    ) throws -> ExtractorSyncSidecarValues {
        var fieldValues: [String: String] = [:]
        for field in declaration.fields where field.isList == false {
            guard let rawValue = raw[field.name] else {
                if field.isRequired {
                    throw ExtractorSyncSidecarError.requiredFieldNotConfigured(
                        field: field.name, configFileName: declaration.configFileName)
                }
                continue
            }
            guard let text = rawValue as? String else {
                throw ExtractorSyncSidecarError.fieldValueNotAString(field: field.name)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if field.isRequired {
                    throw ExtractorSyncSidecarError.requiredFieldNotConfigured(
                        field: field.name, configFileName: declaration.configFileName)
                }
                continue
            }
            if let reason = field.invalidReason(forValue: trimmed) {
                throw ExtractorSyncSidecarError.invalidFieldValue(field: field.name, reason: reason)
            }
            fieldValues[field.name] = trimmed
        }

        let list = declaration.listField
        var items: [String] = []
        if let rawList = raw[list.name] {
            guard let array = rawList as? [Any] else {
                throw ExtractorSyncSidecarError.listValueNotAnArray(field: list.name)
            }
            guard array.count <= ExtractorHostLimits.maximumSyncItemCount else {
                throw ExtractorSyncSidecarError.tooManyItems(
                    field: list.name, count: array.count)
            }
            var seen = Set<String>()
            for (index, entry) in array.enumerated() {
                guard let text = entry as? String else {
                    throw ExtractorSyncSidecarError.itemNotAString(field: list.name, index: index)
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let validation = declaration.itemValidation,
                   let reason = validation.invalidReason(forItem: trimmed) {
                    throw ExtractorSyncSidecarError.invalidItem(item: trimmed, reason: reason)
                }
                guard seen.insert(trimmed).inserted else {
                    throw ExtractorSyncSidecarError.duplicateItem(item: trimmed)
                }
                items.append(trimmed)
            }
        }
        if list.isRequired, items.isEmpty {
            throw ExtractorSyncSidecarError.requiredListIsEmpty(
                field: list.name, configFileName: declaration.configFileName)
        }
        return ExtractorSyncSidecarValues(fieldValues: fieldValues, items: items)
    }
}

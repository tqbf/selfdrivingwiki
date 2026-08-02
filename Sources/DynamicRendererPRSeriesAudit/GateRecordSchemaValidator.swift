import CoreFoundation
import Foundation

// pattern: Functional Core

enum GateRecordSchemaValidator {
    static func validate(instanceData: Data, schemaData: Data) throws {
        let schema = try JSONSerialization.jsonObject(with: schemaData)
        guard let schemaObject = schema as? [String: Any], isSupportedGateRecordSchema(schemaObject) else {
            throw DynamicRendererAuditError.invalidSchema
        }
        try JSONSchemaValidator.validate(instanceData: instanceData, schema: schemaObject)
    }

    private static func isSupportedGateRecordSchema(_ schema: [String: Any]) -> Bool {
        let required: Set<String> = ["schemaVersion", "auditedSHA", "headRefOID", "localHeadOID", "baseRefName", "baseRefOID", "cleanCheckout", "requiredCheckRuns", "review", "commands", "testInventory", "findings", "recordedAt"]
        let properties: Set<String> = required.union(["mutationReport"])
        guard schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema",
              schema["type"] as? String == "object",
              schema["additionalProperties"] as? Bool == false,
              Set(schema["required"] as? [String] ?? []) == required,
              let propertySchemas = schema["properties"] as? [String: Any], Set(propertySchemas.keys) == properties
        else { return false }
        return true
    }
}

enum MutationEvidenceSchemaValidator {
    static func validate(instanceData: Data, schemaData: Data) throws {
        let schema = try JSONSerialization.jsonObject(with: schemaData)
        guard let schemaObject = schema as? [String: Any], isSupportedMutationEvidenceSchema(schemaObject) else {
            throw DynamicRendererAuditError.invalidSchema
        }
        try JSONSchemaValidator.validate(instanceData: instanceData, schema: schemaObject)
    }

    private static func isSupportedMutationEvidenceSchema(_ schema: [String: Any]) -> Bool {
        let required: Set<String> = ["schemaVersion", "auditedSHA", "baseOID", "generatedAt", "command", "toolVersion", "nativeReport", "nativeReportSHA256", "scope", "coveredSymbols", "result", "threshold", "mutants", "passed"]
        guard schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema",
              schema["type"] as? String == "object",
              schema["additionalProperties"] as? Bool == false,
              Set(schema["required"] as? [String] ?? []) == required,
              let properties = schema["properties"] as? [String: Any], Set(properties.keys) == required
        else { return false }
        return true
    }
}

private enum JSONSchemaValidator {
    static func validate(instanceData: Data, schema: [String: Any]) throws {
        let instance = try JSONSerialization.jsonObject(with: instanceData)
        guard validates(instance, against: schema) else { throw DynamicRendererAuditError.invalidSchema }
    }

    private static func validates(_ instance: Any, against schema: [String: Any]) -> Bool {
        if let alternatives = schema["oneOf"] as? [[String: Any]], alternatives.filter({ validates(instance, against: $0) }).count != 1 {
            return false
        }
        if let type = schema["type"] as? String, matches(instance, type: type) == false { return false }
        if let expected = schema["const"], equals(instance, expected) == false { return false }
        if let values = schema["enum"] as? [Any], values.contains(where: { equals(instance, $0) }) == false { return false }

        if let string = instance as? String {
            if let minimum = schema["minLength"] as? Int, string.count < minimum { return false }
            if let pattern = schema["pattern"] as? String,
               string.range(of: pattern, options: .regularExpression) == nil { return false }
        }
        if let array = instance as? [Any] {
            if let minimum = schema["minItems"] as? Int, array.count < minimum { return false }
            if let maximum = schema["maxItems"] as? Int, array.count > maximum { return false }
            if let itemSchema = schema["items"] as? [String: Any], array.allSatisfy({ validates($0, against: itemSchema) }) == false { return false }
        }
        if isJSONInteger(instance), let number = instance as? NSNumber,
           let minimum = schema["minimum"] as? Int,
           number.decimalValue < Decimal(minimum) { return false }
        if let object = instance as? [String: Any] {
            let required = schema["required"] as? [String] ?? []
            guard required.allSatisfy(object.keys.contains) else { return false }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            if schema["additionalProperties"] as? Bool == false,
               object.keys.allSatisfy(properties.keys.contains) == false { return false }
            for (name, propertySchema) in properties {
                if let value = object[name], validates(value, against: propertySchema) == false { return false }
            }
        }
        return true
    }

    private static func matches(_ instance: Any, type: String) -> Bool {
        switch type {
        case "object": instance is [String: Any]
        case "array": instance is [Any]
        case "string": instance is String
        case "boolean": isJSONBoolean(instance)
        case "integer": isJSONInteger(instance)
        case "null": instance is NSNull
        default: false
        }
    }

    private static func equals(_ left: Any, _ right: Any) -> Bool {
        if isJSONBoolean(left) || isJSONBoolean(right) {
            guard isJSONBoolean(left), isJSONBoolean(right),
                  let leftNumber = left as? NSNumber,
                  let rightNumber = right as? NSNumber else { return false }
            return leftNumber.boolValue == rightNumber.boolValue
        }
        if isJSONInteger(left) || isJSONInteger(right) {
            guard isJSONInteger(left), isJSONInteger(right),
                  let leftNumber = left as? NSNumber,
                  let rightNumber = right as? NSNumber else { return false }
            return leftNumber.decimalValue == rightNumber.decimalValue
        }
        if let left = left as? String, let right = right as? String { return left == right }
        return false
    }

    /// JSONSerialization represents booleans as NSNumber subclasses, so Swift's
    /// `as? Int` and `as? Bool` casts cannot preserve the original JSON type.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isJSONInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, isJSONBoolean(value) == false else { return false }
        var decimal = number.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .plain)
        return decimal == rounded
    }
}

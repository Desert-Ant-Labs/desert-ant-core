// The schema a caller brings, and the values that come back.
//
// The schema is an *input*, not something baked into the weights: the model
// is schema-generic, so a new schema is a runtime value and needs no
// retraining. That is why this is a plain value type and not codegen.

import Foundation

/// One field to extract.
public struct Field: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// A verbatim span of the input.
        case string
        /// A number located in the text and parsed by the harness.
        case number
        /// Three-way: absent, false, or true.
        case boolean
        /// Resolved to ISO-8601, relative dates included.
        case datetime
        /// One of `values`, chosen by meaning rather than by exact match.
        case label([String])
        /// Zero or more verbatim spans.
        case array
        /// Zero or more objects, each with these properties: "the order lines",
        /// "the stops of a trip". Extracted by segment and recurse (see
        /// `Nested.swift`): the text is split into candidate item spans and
        /// the properties are extracted from each, so it works where each item
        /// has its own clause or list entry. Properties are flat: an object
        /// inside an object is not supported.
        case objects([Field])
    }

    public let name: String
    public let kind: Kind
    /// A short natural-language hint. This is read by the model, not ignored:
    /// it conditions the encoding, so it is worth writing well.
    public let describe: String?
    /// Whether absence is an expected answer. Stated `true`, a number may come
    /// back null (otherwise it composes a value) and the number and datetime
    /// heads are told absence is expected, which moves their decisions; so
    /// stating it is not the same as the default. Defaults to true.
    public let nullable: Bool
    /// Whether `nullable` was stated rather than defaulted. The number and
    /// datetime composers only abstain for an EXPLICITLY nullable field,
    /// matching the reference's `spec.get("nullable")`.
    let explicitNullable: Bool
    /// Inclusive range for numbers. Out-of-range composed values are clamped,
    /// and the range also enters the number head's own query.
    public let minimum: Double?
    public let maximum: Double?
    /// A unit hint for numbers ("currency", "kg", "hour"). Enters the number
    /// head's query.
    public let unit: String?

    public init(_ name: String, _ kind: Kind, describe: String? = nil,
                nullable: Bool? = nil, minimum: Double? = nil, maximum: Double? = nil,
                unit: String? = nil) {
        self.name = name
        self.kind = kind
        self.describe = describe
        self.nullable = nullable ?? true
        self.explicitNullable = nullable ?? false
        self.minimum = minimum
        self.maximum = maximum
        self.unit = unit
    }

    public static func string(_ n: String, describe: String? = nil, nullable: Bool? = nil) -> Field {
        Field(n, .string, describe: describe, nullable: nullable)
    }
    public static func number(_ n: String, describe: String? = nil, nullable: Bool? = nil,
                              min: Double? = nil, max: Double? = nil,
                              unit: String? = nil) -> Field {
        Field(n, .number, describe: describe, nullable: nullable,
              minimum: min, maximum: max, unit: unit)
    }
    public static func boolean(_ n: String, describe: String? = nil, nullable: Bool? = nil) -> Field {
        Field(n, .boolean, describe: describe, nullable: nullable)
    }
    public static func datetime(_ n: String, describe: String? = nil, nullable: Bool? = nil) -> Field {
        Field(n, .datetime, describe: describe, nullable: nullable)
    }
    public static func label(_ n: String, values: [String], describe: String? = nil,
                             nullable: Bool? = nil) -> Field {
        Field(n, .label(values), describe: describe, nullable: nullable)
    }
    public static func array(_ n: String, describe: String? = nil, nullable: Bool? = nil) -> Field {
        Field(n, .array, describe: describe, nullable: nullable)
    }
    /// An array of objects with `properties`, one per item the text lists.
    public static func objects(_ n: String, properties: [Field], describe: String? = nil,
                               nullable: Bool? = nil) -> Field {
        Field(n, .objects(properties), describe: describe, nullable: nullable)
    }

    /// `name:type(describe)`: the joint-input summary the encoder sees.
    var summary: String {
        var s = "\(name):\(typeName)"
        if let d = describe, !d.isEmpty { s += "(\(d))" }
        return s
    }

    /// `name (describe)`, or `name : type` without one: the cross-attention
    /// query the reader conditions on (`_field_desc` in the reference). The
    /// type is part of the string the model was trained on, so dropping it for
    /// an undescribed field moves decisions: it flipped a label.
    var query: String {
        guard let d = describe, !d.isEmpty else { return "\(name) : \(typeName)" }
        return "\(name) (\(d))"
    }

    /// `build_datetime_schema_text`: the string the DATETIME head attends
    /// over. Carries nullable, which the reader's query does not.
    var datetimeQuery: String {
        var s = "\(name): datetime"
        if let d = describe, !d.isEmpty { s += " \u{2014} \(d)" }
        if explicitNullable, nullable { s += " or null" }
        return s
    }

    /// `build_number_schema_text`: min/max and unit matter to the NUMBER head
    /// and are absent from the reader's query.
    var numberQuery: String {
        var s = "\(name): number"
        if let d = describe, !d.isEmpty { s += " \u{2014} \(d)" }
        if minimum != nil || maximum != nil {
            s += " range \(Self.py(minimum))..\(Self.py(maximum))"
        }
        if let u = unit { s += " unit: \(u)" }
        if explicitNullable, nullable { s += " or null" }
        return s
    }

    /// Python's `str()` of a number, which is what the reference formats the
    /// range with: `0` and `100000` for ints, `None` for a missing bound.
    static func py(_ v: Double?) -> String {
        guard let v else { return "None" }
        return v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
    }

    var isDatetime: Bool { if case .datetime = kind { return true }; return false }
    var isObjects: Bool { if case .objects = kind { return true }; return false }
    var isNumber: Bool { if case .number = kind { return true }; return false }

    var typeName: String {
        switch kind {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .datetime: return "datetime"
        case .label: return "label"
        case .array, .objects: return "array"
        }
    }
}

/// An ordered set of fields.
///
/// ```swift
/// let schema: Schema = [
///     .string("merchant", describe: "the shop or vendor"),
///     .number("amount", describe: "total paid"),
///     .boolean("reimbursable"),
///     .label("category", values: ["food", "travel", "office"]),
///     .datetime("when"),
/// ]
/// ```
public struct Schema: Sendable, ExpressibleByArrayLiteral {
    public var fields: [Field]

    public init(_ fields: [Field]) { self.fields = fields }
    public init(arrayLiteral elements: Field...) { self.fields = elements }

    /// Reject a schema the runtime cannot honor, with the same
    /// ``SchemerError/invalidSchema(_:)`` `extract` would throw. It needs no
    /// model, so an app can check a schema before downloading one.
    public func validate() throws { try Self.validate(fields, nested: false) }

    private static func validate(_ fields: [Field], nested: Bool) throws {
        var seen = Set<String>()
        for f in fields {
            guard !f.name.isEmpty else {
                throw SchemerError.invalidSchema("a field has an empty name")
            }
            guard seen.insert(f.name).inserted else {
                throw SchemerError.invalidSchema("duplicate field name '\(f.name)'")
            }
            switch f.kind {
            case .label(let values):
                guard !values.isEmpty else {
                    throw SchemerError.invalidSchema("label field '\(f.name)' has no values")
                }
                guard values.count <= Schemer.maxLabelValues else {
                    throw SchemerError.invalidSchema(
                        "label field '\(f.name)' has \(values.count) values; "
                        + "the compiled label graph takes at most \(Schemer.maxLabelValues)")
                }
            case .number:
                for bound in [f.minimum, f.maximum] {
                    guard bound?.isFinite ?? true else {
                        throw SchemerError.invalidSchema("number field '\(f.name)' has a non-finite bound")
                    }
                }
                if let lo = f.minimum, let hi = f.maximum, lo > hi {
                    throw SchemerError.invalidSchema(
                        "number field '\(f.name)' has min \(lo) above max \(hi)")
                }
            case .objects(let properties):
                guard !nested else {
                    throw SchemerError.invalidSchema(
                        "field '\(f.name)' nests objects inside objects, which is not supported")
                }
                try validate(properties, nested: true)
            default:
                break
            }
        }
    }
}

/// One extracted value. `null` is a real answer: it means the text did not
/// state the field, which is the case the model is built to detect.
public enum Value: Sendable, Equatable {
    case null
    case string(String)
    case number(Double)
    case boolean(Bool)
    case datetime(String)      // ISO-8601
    case label(String)
    case array([String])
    /// The items of an `objects` field, in the order the text lists them.
    case objects([Record])

    public var isNull: Bool { self == .null }

    /// The value as it appears in JSON.
    public var jsonLiteral: String {
        switch self {
        case .null: return "null"
        case .string(let s), .datetime(let s), .label(let s): return Self.quote(s)
        case .number(let d):
            return d == d.rounded() && abs(d) < 1e15
                ? String(Int64(d)) : String(d)
        case .boolean(let b): return b ? "true" : "false"
        case .array(let xs): return "[" + xs.map(Self.quote).joined(separator: ", ") + "]"
        case .objects(let items): return "[" + items.map(\.jsonLiteral).joined(separator: ", ") + "]"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                out += ch.value < 0x20
                    ? String(format: "\\u%04x", ch.value) : String(ch)
            }
        }
        return out + "\""
    }
}

/// One item of an `objects` field.
///
/// Holds only the properties the item states, in schema order: an item is kept
/// because its first string property was found, and the others are present
/// only when the text gave them, as the reference harness assembles it.
public struct Record: Sendable, Equatable {
    public let names: [String]
    public let values: [Value]

    public init(_ entries: [(String, Value)]) {
        names = entries.map(\.0)
        values = entries.map(\.1)
    }

    /// The property's value, or `.null` when the item does not state it.
    public subscript(_ name: String) -> Value {
        names.firstIndex(of: name).map { values[$0] } ?? .null
    }

    public var entries: [(name: String, value: Value)] { Array(zip(names, values)) }

    var jsonLiteral: String {
        "{" + zip(names, values).map { "\(Value.quote($0)): \($1.jsonLiteral)" }
            .joined(separator: ", ") + "}"
    }
}

/// What `extract` returns: the fields in schema order, plus a JSON rendering.
public struct Extraction: Sendable {
    public let values: [(field: String, value: Value)]
    /// Wall-clock time the extraction took.
    public let duration: TimeInterval
    /// Whether the text was longer than the model reads (about 1,216 tokens
    /// with the schema), so its end was never seen. Values stated only past
    /// that point come back null.
    public let truncated: Bool

    init(values: [(field: String, value: Value)], duration: TimeInterval, truncated: Bool = false) {
        self.values = values
        self.duration = duration
        self.truncated = truncated
    }

    public subscript(_ name: String) -> Value {
        values.first { $0.field == name }?.value ?? .null
    }

    /// Pretty-printed JSON object, fields in schema order.
    public var json: String {
        let body = values
            .map { "  \(Value.string($0.field).jsonLiteral): \($0.value.jsonLiteral)" }
            .joined(separator: ",\n")
        return "{\n\(body)\n}"
    }

    public var dictionary: [String: Value] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.field, $0.value) })
    }
}

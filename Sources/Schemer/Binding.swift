// Schemer's side of the cross-language binding: construction, plus the two
// payload schemas that are genuinely model-specific (what a run takes, and
// what a result looks like). The generic handle lifecycle and the exported
// symbols live in NativeBindings and Native.swift, so this file is only the
// model's adapter.
//
// Nothing about the modality reaches the ABI. Schemer's input happens to be a
// string plus a schema, the way Shapes' is a stroke and Clear's is samples.

import DesertAnt
import FFIBuffer
import Foundation

@_spi(SchemerBindings)
extension Schemer: BoundModel {

    /// Input payload:
    ///
    ///     string text
    ///     u32    fieldCount
    ///     per field:
    ///       string name
    ///       u32    type      0 string, 1 number, 2 boolean, 3 datetime,
    ///                        4 label, 5 array, 6 objects
    ///       string describe  (empty means none)
    ///       u32    nullable  0 false, 1 true, 2 not stated
    ///       if type == label:
    ///         u32 valueCount, then that many strings
    ///       if type == number:
    ///         u32 hasMin, f64 min, u32 hasMax, f64 max
    ///         string unit    (empty means none)
    ///       if type == objects:
    ///         u32 propertyCount, then that many fields in this same format
    ///         (none of them objects)
    ///
    /// "Not stated" is not the same answer as true. Unstated, a field may
    /// still come back null; stated, the number and datetime heads are also
    /// told so in their query text (`or null`), which moves their decisions.
    /// A binding that always wrote 1 would get different values than the
    /// Swift API for the same schema, so it writes 2 unless the caller said.
    ///
    /// Options payload:
    ///
    ///     string anchor      "today=YYYY-MM-DD"; empty means the device clock
    ///
    /// Result payload:
    ///
    ///     u32 fieldCount
    ///     per field:
    ///       u32 kind         0 null, 1 string, 2 number, 3 boolean,
    ///                        4 datetime, 5 label, 6 array, 7 objects
    ///       then that kind's body: a string for 1/4/5, f64 for 2, u32 for 3,
    ///       u32 count + that many strings for 6, nothing for 0, and for 7:
    ///       u32 itemCount, then per item u32 entryCount and per entry a
    ///       string name followed by a value in this same kind-and-body form.
    ///       An item holds only the properties it states, in schema order.
    ///     u32 truncated      1 when the text ran past what the model reads
    ///                        (added after 1.0; a reader may stop before it)
    ///
    /// Fields come back in schema order, so a host can zip them against what
    /// it wrote rather than matching on name.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var options = options
        guard let (text, schema) = SchemerBinding.fields(from: input) else { return nil }

        // An empty payload means SDK defaults, so this must match the default
        // every SDK declares for `now` (the device clock), not a date of its own.
        let anchor = options.isEmpty ? "" : options.string()
        let now = Self.date(fromAnchor: anchor) ?? Date()

        let extraction: Extraction
        do { extraction = try await extract(from: text, schema: schema, now: now) }
        catch { return nil }

        var w = FFIWriter()
        w.u32(extraction.values.count)
        for (_, value) in extraction.values { Self.write(value, to: &w) }
        w.u32(extraction.truncated ? 1 : 0)
        return w.bytes
    }

    static func write(_ value: Value, to w: inout FFIWriter) {
        switch value {
        case .null:
            w.u32(0)
        case .string(let s):
            w.u32(1); w.string(s)
        case .number(let d):
            w.u32(2); w.f64(d)
        case .boolean(let b):
            w.u32(3); w.u32(b ? 1 : 0)
        case .datetime(let s):
            w.u32(4); w.string(s)
        case .label(let s):
            w.u32(5); w.string(s)
        case .array(let xs):
            w.u32(6); w.u32(xs.count)
            for x in xs { w.string(x) }
        case .objects(let items):
            w.u32(7); w.u32(items.count)
            for item in items {
                w.u32(item.names.count)
                for (name, v) in item.entries { w.string(name); write(v, to: &w) }
            }
        }
    }

    /// `today=YYYY-MM-DD` back to a Date, so a host can pin the anchor and get
    /// reproducible datetimes. Anything unparseable falls back to the clock
    /// rather than failing the run.
    ///
    /// Noon of that day in `timeZone`, the zone `anchorString` reads the day
    /// back in, so the round trip returns the same day wherever the device
    /// is (midnight can fall in a DST gap, noon never does).
    @_spi(SchemerBindings)
    public static func date(fromAnchor anchor: String, in timeZone: TimeZone = .current) -> Date? {
        guard anchor.hasPrefix("today=") else { return nil }
        let parts = anchor.dropFirst("today=".count).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]),
              let d = Int(parts[2]) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: c)
    }
}

/// How the generic bindings construct Schemer.
public enum SchemerBinding: ModelBinding {
    public static let id = SchemerModel.id

    /// Decode the input payload (documented on `run(input:options:)`) into the
    /// text and the schema the Swift API would have built for the same fields.
    /// `nil` for a payload no conforming host writes.
    static func fields(from input: FFIReader) -> (text: String, schema: Schema)? {
        var input = input
        let text = input.string()
        guard let fields = readFields(&input, nested: false) else { return nil }
        return (text, Schema(fields))
    }

    private static func readFields(_ input: inout FFIReader, nested: Bool) -> [Field]? {
        // Every field is at least a name, a type, a description and a
        // nullability: 16 bytes. A count the payload cannot hold is malformed,
        // and is refused before anything is reserved for it.
        let count = input.u32()
        // `u32()` wraps negative in a 32-bit `Int` (wasm), so check both ends.
        guard count >= 0, count <= input.remaining / 16 else { return nil }
        var fields: [Field] = []
        fields.reserveCapacity(count)
        for _ in 0..<count {
            let name = input.string()
            let type = input.u32()
            let describe = input.string()
            let nullable: Bool?
            switch input.u32() {
            case 0: nullable = false
            case 1: nullable = true
            default: nullable = nil
            }
            let kind: Field.Kind
            var minimum: Double?, maximum: Double?, unit: String?
            switch type {
            case 0: kind = .string
            case 1:
                kind = .number
                let hasMin = input.u32() != 0, lo = input.f64()
                let hasMax = input.u32() != 0, hi = input.f64()
                let u = input.string()
                minimum = hasMin ? lo : nil
                maximum = hasMax ? hi : nil
                unit = u.isEmpty ? nil : u
            case 2: kind = .boolean
            case 3: kind = .datetime
            case 4: kind = .label(input.strings())
            case 5: kind = .array
            case 6 where !nested:
                guard let properties = readFields(&input, nested: true) else { return nil }
                kind = .objects(properties)
            default: return nil          // unknown type: a host bug, not a null
            }
            fields.append(Field(name, kind,
                                describe: describe.isEmpty ? nil : describe,
                                nullable: nullable, minimum: minimum, maximum: maximum,
                                unit: unit))
        }
        return fields
    }

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Schemer(directory: directory, cacheRoot: cacheRoot)
    }
}

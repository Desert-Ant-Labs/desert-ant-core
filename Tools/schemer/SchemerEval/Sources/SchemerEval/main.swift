import Foundation
@_spi(SchemerEval) import Schemer

// Usage:
//   SCHEMER_MODEL_DIR=<bundle> swift run -c release SchemerEval <records.jsonl> <preds.jsonl> [shard i/n]
//
// Each input line is an eval record with `text`, `schema` (the training repo's
// schema JSON), an optional `anchor` (ISO date) and an id (`pooled_id` or
// `id`). Records without an anchor run against 2026-06-25, the date the eval
// sets were written against. Output lines are {"id", "pred", "truncated",
// "ms"} or {"id", "error"}. Existing ids in the output are skipped, so an
// interrupted run resumes.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: SchemerEval <records.jsonl> <preds.jsonl> [i/n]\n".data(using: .utf8)!)
    exit(2)
}
let inPath = args[1], outPath = args[2]
var shard = (0, 1)
if args.count > 3 {
    let p = args[3].split(separator: "/").compactMap { Int($0) }
    if p.count == 2 { shard = (p[0], p[1]) }
}

func field(_ name: String, _ s: [String: Any]) -> Field {
    let d = s["describe"] as? String
    let n = s["nullable"] as? Bool
    switch s["type"] as? String {
    case "number":
        return .number(name, describe: d, nullable: n, min: (s["min"] as? NSNumber)?.doubleValue,
                       max: (s["max"] as? NSNumber)?.doubleValue, unit: s["unit"] as? String)
    case "boolean": return .boolean(name, describe: d, nullable: n)
    case "datetime": return .datetime(name, describe: d, nullable: n)
    case "label":
        return .label(name, values: (s["values"] as? [Any] ?? []).map { "\($0)" }, describe: d, nullable: n)
    case "array":
        if let items = s["items"] as? [String: Any], items["type"] as? String == "object",
           let props = items["properties"] as? [String: Any] {
            // JSONSerialization loses key order; the eval writer keeps it in
            // `property_order` when it matters, otherwise sort for determinism.
            let order = (s["property_order"] as? [String]) ?? props.keys.sorted()
            return .objects(name, properties: order.compactMap { k in
                (props[k] as? [String: Any]).map { field(k, $0) } }, describe: d, nullable: n)
        }
        return .array(name, describe: d, nullable: n)
    default: return .string(name, describe: d, nullable: n)
    }
}

func json(_ v: Value) -> Any {
    switch v {
    case .null: return NSNull()
    case .string(let s), .datetime(let s), .label(let s): return s
    case .number(let d): return d
    case .boolean(let b): return b
    case .array(let xs): return xs
    case .objects(let items):
        return items.map { r in Dictionary(uniqueKeysWithValues: r.entries.map { ($0.name, json($0.value)) }) }
    }
}

func anchorDate(_ a: String?) -> Date {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withFullDate]
    iso.timeZone = TimeZone.current
    if let a, let d = iso.date(from: String(a.prefix(10))) { return d.addingTimeInterval(12 * 3600) }
    return iso.date(from: "2026-06-25")!.addingTimeInterval(12 * 3600)
}


var done = Set<String>()
if let existing = try? String(contentsOfFile: outPath, encoding: .utf8) {
    for l in existing.split(separator: "\n") {
        if let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
           let id = o["id"] as? String { done.insert(id) }
    }
}
if !FileManager.default.fileExists(atPath: outPath) {
    FileManager.default.createFile(atPath: outPath, contents: nil)
}
let out = FileHandle(forWritingAtPath: outPath)!
out.seekToEndOfFile()

// SCHEMER_LEVERS_OFF=a,b switches named harness rules off, to measure them.
if let off = ProcessInfo.processInfo.environment["SCHEMER_LEVERS_OFF"] {
    Schemer.disableHarnessRules(Set(off.split(separator: ",").map(String.init)))
}
let schemer = Schemer(directory: ProcessInfo.processInfo.environment["SCHEMER_MODEL_DIR"])
try await schemer.prewarm()

let lines = try String(contentsOfFile: inPath, encoding: .utf8).split(separator: "\n")
var n = 0
let t0 = Date()
for (i, line) in lines.enumerated() where i % shard.1 == shard.0 {
    guard let rec = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    else { continue }
    let id = (rec["pooled_id"] as? String) ?? (rec["id"] as? String) ?? "\(i)"
    if done.contains(id) { continue }
    let text = rec["text"] as? String ?? ""
    let raw = rec["schema"] as? [String: Any] ?? [:]
    let order = (rec["schema_order"] as? [String]) ?? raw.keys.sorted()
    let schema = Schema(order.compactMap { k in (raw[k] as? [String: Any]).map { field(k, $0) } })
    var row: [String: Any] = ["id": id]
    do {
        let r = try await schemer.extract(from: text, schema: schema, now: anchorDate(rec["anchor"] as? String))
        row["pred"] = Dictionary(uniqueKeysWithValues: r.values.map { ($0.field, json($0.value)) })
        row["truncated"] = r.truncated
        row["ms"] = Int(r.duration * 1000)
    } catch {
        row["error"] = "\(error)"
    }
    out.write(try JSONSerialization.data(withJSONObject: row))
    out.write("\n".data(using: .utf8)!)
    n += 1
    if n % 200 == 0 {
        let rate = Double(n) / Date().timeIntervalSince(t0)
        FileHandle.standardError.write("\(n) records, \(String(format: "%.2f", rate)) rec/s\n".data(using: .utf8)!)
    }
}
FileHandle.standardError.write("done: \(n) records\n".data(using: .utf8)!)

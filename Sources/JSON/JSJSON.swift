#if os(WASI)
import JavaScriptKit

/// WebAssembly JSON parser: the host engine's `JSON.parse`, walked into a
/// `JSONValue` for the Codable decoder.
func parseJSONValue(_ text: String) throws -> JSONValue {
    let json = JSObject.global.JSON.object!
    return convert(json.parse!(text))
}

enum JSONError: Error { case invalid }

private func convert(_ v: JSValue) -> JSONValue {
    if v.isNull || v.isUndefined { return .null }
    if let b = v.boolean { return .bool(b) }
    if let n = v.number { return .number(n) }
    if let s = v.string { return .string(s) }
    guard let obj = v.object else { return .null }
    if let array = JSArray(obj) {
        return .array(array.map { convert($0) })
    }
    var out: [String: JSONValue] = [:]
    let keys = JSObject.global.Object.function!.keys!(obj)
    if let keyArray = keys.object.flatMap(JSArray.init) {
        for key in keyArray {
            if let k = key.string { out[k] = convert(obj[k]) }
        }
    }
    return .object(out)
}
#endif

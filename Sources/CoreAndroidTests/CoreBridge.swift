// A pure `swift test` can't validate the Android backends: Regex/JSON delegate
// to the host (java.util.regex / the host JSON parser) through CHostBridge
// callbacks that only a JVM installs. So an instrumented Android test loads this
// as a JNI library, calls `runChecks` with the host class, and asserts the
// result in Kotlin (see androidtest/).
//
// `runChecks` installs the bridge, exercises the host-backed paths (Regex, JSON
// decode) and the platform-ICU path (NFKC), and returns a failure summary —
// an empty string means every check passed. Android-only; empty elsewhere.

#if os(Android)
import Android
import HostBridge
import Regex
import JSON
import TextNormalization

@_cdecl("Java_ai_desertant_core_androidtest_CoreBridge_runChecks")
public func coreBridgeRunChecks(_ env: HostEnv, _ clazz: jclass?, _ host: jclass?) -> jstring? {
    // Wire host_regex_matches / host_json_parse to the host class's static methods.
    installHostBridge(env, host)

    var failures: [String] = []

    // Regex: the Android backend delegates to the host's java.util.regex.
    do {
        let re = try Pattern(#"(\d+)"#)
        if let match = "id 42".firstMatch(of: re) {
            let captured = match[1].substring.map(String.init) ?? ""
            if captured != "42" { failures.append("regex captured '\(captured)', expected '42'") }
        } else {
            failures.append("regex: no match")
        }
    } catch {
        failures.append("regex threw: \(error)")
    }

    // JSON: the Android backend decodes via the host's JSON parser.
    struct Person: Decodable, Equatable { let name: String; let age: Int }
    do {
        let person = try JSONDecoder().decode(Person.self, from: #"{"name":"Ada","age":36}"#)
        if person != Person(name: "Ada", age: 36) { failures.append("json decoded \(person)") }
    } catch {
        failures.append("json threw: \(error)")
    }

    // TextNormalization: NFKC via the platform ICU (CAndroidICU), no host needed.
    if "\u{FB01}".nfkc != "fi" { failures.append("nfkc did not fold the fi ligature") }

    let summary = failures.joined(separator: " | ")
    return summary.withCString { env.pointee!.pointee.NewStringUTF(env, $0) }
}
#endif

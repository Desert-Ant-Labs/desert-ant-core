// A pure `swift test` can't validate the Android backends: Regex/JSON delegate
// to the host (java.util.regex / the host JSON parser) through CHostBridge
// callbacks that only a JVM installs. So an instrumented Android test loads this
// as a JNI library, calls `runChecks` with the host class, and asserts the
// result in Kotlin (see androidtest/).
//
// `runChecks` installs the bridge, exercises the host-backed paths (Regex, JSON
// decode, NFKC), and returns a failure summary; an empty string means every
// check passed. `usageContext` returns the usage context the core builds from
// the host's device facts. `post` sends one request through the real HTTP
// transport. Android-only; empty elsewhere.

#if os(Android)
import Android
import Dispatch
import HostBridge
import PlatformSupport
import Regex
import JSON
import TextNormalization
import Usage

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

    // TextNormalization: NFKC via the host's java.text.Normalizer.
    if "\u{FB01}".nfkc != "fi" { failures.append("nfkc did not fold the fi ligature") }

    let summary = failures.joined(separator: " | ")
    return summary.withCString { env.pointee!.pointee.NewStringUTF(env, $0) }
}

// The usage context a client on this device sends, as sorted "key=value" lines,
// through the real path: the host's device-facts and opt-out callbacks, the
// Android DeviceContext and the client's sanitizing. Nothing is posted; the
// send only captures the body.
@_cdecl("Java_ai_desertant_core_androidtest_CoreBridge_usageContext")
public func coreBridgeUsageContext(_ env: HostEnv, _ clazz: jclass?, _ host: jclass?) -> jstring? {
    installHostBridge(env, host)
    var sent: [IngestBody] = []
    let client = makeClient(
        appId: "ai.desertant.core.androidtest", platform: "android", storage: InMemoryStorage(),
        send: { body, _ in sent.append(body) }
    )
    client.load()
    let context = sent.first?.events.first?.context ?? [:]
    let lines = context.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    return lines.withCString { env.pointee!.pointee.NewStringUTF(env, $0) }
}

private final class Outcome: @unchecked Sendable { var text = "" }

// One POST to `url`, key in `Authorization`, through the path a usage send takes: PlatformSupport's
// httpPOST, the host's httpRequest callback, HttpURLConnection. Returns
// "<status> <body>", or "error: ..." when no response came back.
@_cdecl("Java_ai_desertant_core_androidtest_CoreBridge_post")
public func coreBridgePost(_ env: HostEnv, _ clazz: jclass?, _ host: jclass?, _ url: jbyteArray?) -> jstring? {
    installHostBridge(env, host)
    let target = String(decoding: hostCopyBytes(env, url) ?? [], as: UTF8.self)
    let outcome = Outcome()
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let response = try await httpPOST(
                target, body: Array(#"{"events":[]}"#.utf8), headers: ["Authorization": "Bearer pk_test"]
            )
            outcome.text = "\(response.status) \(String(decoding: response.body, as: UTF8.self))"
        } catch {
            outcome.text = "error: \(error)"
        }
        done.signal()
    }
    done.wait()
    return outcome.text.withCString { env.pointee!.pointee.NewStringUTF(env, $0) }
}
#endif

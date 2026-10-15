// A pure `swift test` can't validate the Android backends: Regex/JSON delegate
// to the host (java.util.regex / the host JSON parser) through CHostBridge
// callbacks that only a JVM installs. So an instrumented Android test loads this
// as a JNI library, calls `runChecks` with the host class, and asserts the
// result in Kotlin (see androidtest/).
//
// `runChecks` installs the bridge, exercises the host-backed paths (Regex, JSON
// decode, NFKC), and returns a failure summary; an empty string means every
// check passed. `post` sends one request through the real HTTP transport.
// `verifyLicense` checks a license token through the host's java.security
// verifier. Android-only; empty elsewhere.

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

private final class Outcome: @unchecked Sendable { var text = "" }
private final class Verdict: @unchecked Sendable { var verified = false }

// One POST to `url`, key in `Authorization`, through the path a license request takes: PlatformSupport's
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

// Whether the core accepts `token` under the `kid=key` lines in `keys`, via verifyLicense on a non-JNI thread.
@_cdecl("Java_ai_desertant_core_androidtest_CoreBridge_verifyLicense")
public func coreBridgeVerifyLicense(
    _ env: HostEnv, _ clazz: jclass?, _ host: jclass?, _ token: jbyteArray?, _ keys: jbyteArray?
) -> jboolean {
    installHostBridge(env, host)
    let text = String(decoding: hostCopyBytes(env, token) ?? [], as: UTF8.self)
    var publicKeys: [String: String] = [:]
    for line in String(decoding: hostCopyBytes(env, keys) ?? [], as: UTF8.self).split(separator: "\n") {
        guard let equals = line.firstIndex(of: "=") else { continue }
        publicKeys[String(line[..<equals])] = String(line[line.index(after: equals)...])
    }
    let verdict = Verdict()
    let done = DispatchSemaphore(value: 0)
    Task {
        verdict.verified = await licenseTokenVerifies(text, publicKeys: publicKeys)
        done.signal()
    }
    done.wait()
    return jboolean(verdict.verified ? 1 : 0)
}
#endif

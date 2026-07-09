# desert-ant-core

Reusable, cross-platform Swift building blocks shared by Desert Ant Labs'
on-device model SDKs (redact, emo, shapes, ...).

Each module exposes one small public API and picks a per-platform backend behind
it, so the code that uses it never sees a platform `#if`:

| Module | API | Apple / Linux | Android | WebAssembly |
|---|---|---|---|---|
| `Regex` (type `Pattern`) | stdlib-`Regex`-shaped matching | `NSRegularExpression` | `java.util.regex` (via `CHostBridge`) | JS `RegExp` |
| `JSON` | `Codable` decoding | `Foundation.JSONDecoder` | host JSON parser (via `CHostBridge`) | JS `JSON.parse` |
| `CHostBridge` | generic host-callback C bridge | - | installed by a JNI shim | - |

The design deliberately avoids linking Foundation on Android and wasm (it would
add a ~40 MB ICU blob); instead it calls the host platform's own regex/JSON,
which are already loaded. See each module's source header for details.

## Regex

```swift
import Regex

let re = try Pattern(#"(\d{4})-(\d{2})"#)    // or `try regex(...)`; `rx("...")` traps, for constants
if let m = text.firstMatch(of: re) {        // reads like the standard library
    text[m.range]        // Range<String.Index>  (whole match)
    m[1].substring       // Substring?           (capture 1)
}
for m in text.matches(of: re) { ... }
re.wholeMatch(in:); re.prefixMatch(in:); re.ignoresCase(); re.contains(in:)
```

The module is `Regex` but the type is `Pattern`: a type named `Regex` would
clash with the standard library's `Regex` and can't be module-qualified. Use
`Pattern(_:)` / `regex(_:)` / `rx(_:)` and the `String` matching methods
(`text.firstMatch(of:)`, `text.matches(of:)`, ...). It does not conform to
`RegexComponent` (that would force the stdlib engine), so regex literals and
generic `RegexComponent` contexts don't accept it.

## JSON

```swift
import JSON

let user = try JSONDecoder().decode(User.self, from: jsonString)   // or from: [UInt8]
```

Same shape as `Foundation.JSONDecoder`. On Apple/Linux it wraps Foundation's; on
Android/wasm it drives standard-library `Codable` over a JSON tree the host
parses (no Foundation, no hand-rolled grammar). Input is `String`/`[UInt8]`
because `Data` is Foundation-only.

## Android wiring

On Android, `Regex`/`JSON` call `host_regex_matches` / `host_json_parse` from
`CHostBridge`; a runtime shim (typically a JNI layer) installs the
implementations once via `host_set_regex_matches` / `host_set_json_parse`. See
`Sources/CHostBridge/include/CHostBridge.h` for the contract.

// JSHost's declarations are body-less `@JSFunction` / `@JSGetter` members, which
// only parse where the BridgeJS macros exist. Swift parses inactive `#if` blocks
// for syntax, so `#if os(WASI)` is not enough: an older toolchain rejects the file
// while building for Apple or Android, and this package supports Swift 5.9+.
//
// So Package.swift points this target at this file instead of `Host.swift` unless
// the build is actually a wasm build. Nothing off wasm imports JSHost.

# Android testing

Choose the least expensive test environment that can establish the contract.
Plain JVM tests are the default. Robolectric adds Android framework behavior on
the host JVM, with extra startup, dependencies and SDK downloads. Instrumented
tests run on Android itself. The selection policy is in [AGENTS.md](../../AGENTS.md).

## Plain JVM tests

Use plain JUnit in `src/test` for code that does not need Android framework
implementations. FFI encoding, model handle ownership, exception mapping and
pure Kotlin calculations belong here. A fake `NativeModelApi` lets these tests
exercise the model shell without loading a native library.

[LoadedModelTest](../../kotlin/src/test/kotlin/ai/desertant/core/LoadedModelTest.kt)
and [HostBridgeTest](../../kotlin/src/test/kotlin/ai/desertant/core/HostBridgeTest.kt)
cover logic this way. Keep them plain JVM tests as new cases are added.

## Robolectric tests

Use Robolectric in `src/test` when an assertion needs an Android framework
implementation. Keep it in a separate class with `RobolectricTestRunner`, so
unrelated logic does not pay for an Android sandbox.

The setup is local to `:core`, with a test-only dependency in
`kotlin/build.gradle.kts` and a version in `gradle/libs.versions.toml`. It is not
enabled by the shared Android convention plugin. The current tests run on
APIs 24 and 37:

- [AndroidStorageTest](../../kotlin/src/test/kotlin/ai/desertant/core/AndroidStorageTest.kt)
  checks package identity, the named preference store, constructor ordering,
  host overrides and device-protected Context selection with a fake native API.
- [FaceprintSerializationTest](../../kotlin/src/test/kotlin/ai/desertant/core/FaceprintSerializationTest.kt)
  checks Android Base64/JSON round trips, a fixed float32 byte fixture and
  malformed input without loading a model.

Add another API only when it tests a specific version boundary. More cases
about arithmetic or handle ownership should remain plain JUnit tests. A
preference round trip or bridge reset does not establish persistence across
process death, and device-protected storage selection does not establish
access before the first unlock.

Run both local test types without a connected device:

```sh
./gradlew :core:testDebugUnitTest
```

To run just the Robolectric storage cases while developing:

```sh
./gradlew :core:testDebugUnitTest --tests 'ai.desertant.core.AndroidStorageTest'
```

## Instrumented tests

Use `src/androidTest` for shipping native libraries, JNI callbacks, LiteRT,
model inference and platform behavior that host simulation cannot establish.
This includes real codecs, hardware bitmaps, pre-unlock access and persistence
across process death. JVM HTTP or signature tests can check the bridge's logic,
but Android networking and cryptographic provider compatibility require an
Android runtime. The same applies to Unicode and regex differences.

Run the regular suite with a connected emulator or device:

```sh
mise run test:android
```

That task also runs the core's plain JVM and Robolectric tests. The focused
runtime matrix and its preparation commands are described in
[Android Unicode compatibility](android-unicode.md). Keep that matrix as the
compatibility gate; Robolectric complements it.

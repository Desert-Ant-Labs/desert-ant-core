# TongueAndroidExample

A tiny Android app for trying Tongue with the Maven Central package
`ai.desertant:tongue`.

## Run

Connect a device or start an emulator, then:

```bash
./gradlew :app:installDebug
```

Type in any language and watch the answer update as you type. Everything runs on
the main thread — no coroutines, no debounce, nothing downloaded — because a
detection is arithmetic over 2 MB of weights that ship inside the artifact.

Until `ai.desertant:tongue` is on Maven Central, install it into your local Maven
repository first:

```bash
cd ../../packages/tongue-kotlin && ./gradlew publishToMavenLocal
```

`settings.gradle.kts` lists `mavenLocal()`, so the app resolves it from there.

Do **not** use `mise run publish-android` for this. That task runs
`publishAndReleaseToMavenCentral`: with no credentials it aborts before Gradle,
and *with* credentials — the `mise.local.toml` PUBLISHING.md tells a maintainer to
create — it irrevocably publishes the current version to Maven Central as a side
effect of building a demo.

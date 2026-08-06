# Desert Ant Android convention plugins

Two plugins that carry the Android build/publish boilerplate every
`packages/<model>-kotlin` module and `kotlin/` (the core AAR) would otherwise
copy (~200 lines of `build.gradle.kts` + `swift-android.gradle.kts` each):

- **`ai.desertant.model-sdk`** - a model's AAR module. Applies AGP + Kotlin,
  configures the Android boilerplate, wires the Swift JNI cross-compile
  (`mise run build:android-natives <model>`), depends on `ai.desertant:core`, and
  applies the publishing convention below.
- **`ai.desertant.publish`** - the Maven Central publishing convention on its
  own: Central portal upload, signing when a key is present, one release variant
  with sources and javadoc, and the shared source-available POM. Used by the core
  AAR, which is not a model.

Each model AAR contains only its model-specific JNI library; the core dependency
supplies LiteRT once to an app that imports one or several models. Model weights
stay downloads, into the app cache or a directory the app provides.

## Using them

This is an **included build** of the repo root (`settings.gradle.kts`), so the
modules here resolve it from the checkout - no version, and nothing has to be
published before a model AAR can be built. A module is then:

```kotlin
// packages/<model>-kotlin/build.gradle.kts
plugins { id("ai.desertant.model-sdk") }

desertAntSdk { description = "On-device ... for Android." }
```

Everything else is derived: the model id is the Gradle project name (`:emo` from
`packages/emo-kotlin`), the group and version come from the root build (which
reads `VERSION`), and the namespace, coordinates, POM, core dependency, and
instrumentation-test dependencies follow from those.

It is also published to Maven Central as
`ai.desertant:model-sdk-gradle-plugin`, versioned with desert-ant-core's
`vX.Y.Z` tags, for anything consuming it from outside this repo.

## Build and publish

```bash
./gradlew -p gradle-plugin build     # compile and test it
mise run publish:maven               # ships it with everything else on a release
mise run publish:maven --local       # to ~/.m2, keyless, for testing consumers
```

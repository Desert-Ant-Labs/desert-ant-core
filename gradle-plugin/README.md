# Desert Ant Android convention plugins

Four plugins that carry the Android build/publish boilerplate every
`packages/<model>-kotlin` module and `kotlin/` (the core AAR) would otherwise
copy:

- **`ai.desertant.android-library`** - the Android defaults every AAR shares:
  AGP, which compiles the Kotlin too (built-in Kotlin), with compileSdk, minSdk,
  the JVM target and the Kotlin floor from `gradle/libs.versions.toml`. Applied
  by the core AAR, and by `model-sdk`.
- **`ai.desertant.model-sdk`** - a model's AAR module. Applies the defaults
  above, wires the Swift JNI cross-compile
  (`mise run build:android-natives <model>`), depends on `ai.desertant:core`, and
  applies the publishing convention below.
- **`ai.desertant.jvm-model-sdk`** - a pure-Kotlin model (Tongue): a plain JVM
  jar at the Kotlin floor, with no native code and no `ai.desertant:core`
  dependency.
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

Versions come from the root build's catalog, `gradle/libs.versions.toml`, which
this build reads too (`settings.gradle.kts`), so the plugin versions the root
applies and the ones these conventions compile against are the same.

It is not published. Up to 4.3.0 it also went to Maven Central as
`ai.desertant:model-sdk-gradle-plugin`; those versions stay there, and no later
one will.

## Build

```bash
./gradlew -p gradle-plugin build     # compile it
```

The root build compiles it as part of any Android task, so there is no separate
step before `mise run build:android` or `mise run publish:maven`.

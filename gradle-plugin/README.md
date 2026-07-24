# Desert Ant model-SDK Gradle plugins

Two convention plugins that carry the Android build/publish boilerplate the
Desert Ant model SDKs' `<model>-kotlin` modules used to each copy (~200 lines of
`build.gradle.kts` + `swift-android.gradle.kts` per repo):

- **`ai.desertant.model-sdk`** - the main AAR module. Applies AGP + Kotlin +
  vanniktech, configures the Android/publish boilerplate + POM, drives the Swift
  native build (`mise run android-natives`, replacing `swift-android.gradle.kts`),
  and depends on `ai.desertant:core` and the `:*-tflite-resources` module.
- **`ai.desertant.model-resources`** - the optional bundled-model module.

Published to Maven Central as `ai.desertant:model-sdk-gradle-plugin`, versioned
with desert-ant-core's `vX.Y.Z` tags.

## Using it from a model repo

`packages/<model>-kotlin/settings.gradle.kts` must resolve plugins from Maven
Central:

```kotlin
pluginManagement { repositories { mavenCentral(); google(); gradlePluginPortal() } }
```

`packages/<model>-kotlin/build.gradle.kts`:

```kotlin
plugins { id("ai.desertant.model-sdk") version "0.4.2" }
version = "1.2.3"                        // single-sourced for mise set-version/check-version
desertAntSdk { description = "On-device ... for Android." }
```

`packages/<model>-kotlin/<model>-tflite-resources/build.gradle.kts` (no version
on the plugin - the two ids ship in one jar, already on the classpath):

```kotlin
plugins { id("ai.desertant.model-resources") }
version = "1.2.3"
desertAntResources { tfliteFiles = listOf("emo.tflite", "emo_meta.json", "emo_tokenizer.bin") }
```

Everything else (namespace, coordinates, POM name/url/license/scm, the core +
coroutines + resources dependencies, the `buildSwiftNatives` task) is derived
from the Gradle root project name (`rootProject.name = "<model>"`). Override the
core dependency version with `desertAntSdk { coreVersion = "X.Y.Z" }`.

## Build / publish

`mise run build-plugin`, `mise run publish-plugin` (Maven Central), or
`mise run publish-plugin-local` (keyless, to `~/.m2`, for testing consumers).
The `Publish Gradle plugin` workflow publishes it on a `vX.Y.Z` tag when
`gradle-plugin/` changed.

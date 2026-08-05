# Desert Ant model-SDK Gradle plugin

A convention plugin that carries the Android build/publish boilerplate the
Desert Ant model SDKs' `<model>-kotlin` modules used to each copy (~200 lines of
`build.gradle.kts` + `swift-android.gradle.kts` per repo):

- **`ai.desertant.model-sdk`** - the AAR module. Applies AGP + Kotlin +
  vanniktech, configures the Android/publish boilerplate + POM, drives the Swift
  native build (`mise run android-natives`, replacing `swift-android.gradle.kts`),
  and depends on `ai.desertant:core`.

Each model AAR contains only its model-specific JNI library. The core dependency
supplies LiteRT once to an app that imports one or several models. Model weights
remain downloads into the app cache or a directory the app provides.

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
plugins { id("ai.desertant.model-sdk") version "0.6.0" }
version = "1.2.3"                        // single-sourced for mise set-version/check-version
desertAntSdk { description = "On-device ... for Android." }
```

Everything else (namespace, coordinates, POM name/url/license/scm, the core
and instrumentation-test dependencies, the `buildSwiftNatives` task) is derived
from the Gradle root project name (`rootProject.name = "<model>"`). Override the
core dependency version with `desertAntSdk { coreVersion = "X.Y.Z" }`.

## Build / publish

`mise run build-plugin`, `mise run publish-plugin` (Maven Central), or
`mise run publish-plugin-local` (keyless, to `~/.m2`, for testing consumers).
The `Publish Gradle plugin` workflow publishes it on a `vX.Y.Z` tag when
`gradle-plugin/` changed.

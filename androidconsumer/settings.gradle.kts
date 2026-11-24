// The consumer fixture: an app that depends on ai.desertant:* the way a
// customer's does, through Maven coordinates, never through the root build's
// projects. `mise run check:android-consumer` publishes the SDKs into a local
// repo and builds this against them, once on the oldest Kotlin we commit to
// for apps and once on the compiler the SDKs use.
pluginManagement {
    // No default on purpose: a default would quietly stand in for one of the two
    // compilers the check exists to prove.
    val kotlin = settings.providers.gradleProperty("dalConsumerKotlin").orNull
        ?: error("pass -PdalConsumerKotlin=<version>, or run `mise run check:android-consumer`")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    // AGP is the SDK build's, from the shared catalog (build.gradle.kts here);
    // only Kotlin varies between the two runs. The app has no Kotlin plugin of
    // its own (AGP 9 compiles Kotlin itself), so this one plugin picks the
    // compiler for both modules.
    plugins {
        id("org.jetbrains.kotlin.jvm") version kotlin
    }
}

// The jvm module compiles on JDK 17, Tongue's stated JVM floor.
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // ai.desertant comes only from the repo the check task publishes into
        // (-Dmaven.repo.local). If that publish is missing, resolution fails
        // instead of picking up a release of the same version from Central.
        exclusiveContent {
            forRepository { mavenLocal() }
            filter { includeGroup("ai.desertant") }
        }
        google()
        mavenCentral()
    }
    // The SDK build's catalog, for AGP only. The app's SDK levels and JVM target
    // stay literal in app/build.gradle.kts: they are what we promise apps (the
    // README's minSdk floor), so they must not move when the SDK's do.
    versionCatalogs {
        create("libs") { from(files("../gradle/libs.versions.toml")) }
    }
}

rootProject.name = "desert-ant-android-consumer"

include("app")
include("handshake")
include("jvm")

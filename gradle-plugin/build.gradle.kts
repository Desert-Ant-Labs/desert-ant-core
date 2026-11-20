// The Android convention plugins for this repo: `ai.desertant.android-library`
// for the defaults every AAR shares, `ai.desertant.model-sdk` for a model's AAR
// module, `ai.desertant.jvm-model-sdk` for a pure-Kotlin model, and
// `ai.desertant.publish` for ai.desertant:core. The root build includes this one
// (settings.gradle.kts), so the modules here resolve it from the checkout. It is
// not published: nothing outside this repo applies it.
plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-gradle-plugin`
}

// Gradle loads these classes next to its own embedded Kotlin and stdlib, not
// the catalog's compiler, which can move past the floor. Built at the SDKs'
// floor they stay readable by, and within the stdlib of, the Gradle this repo
// runs on, whatever `kotlin` becomes.
kotlin {
    val floor = org.jetbrains.kotlin.gradle.dsl.KotlinVersion.fromVersion(
        libs.versions.kotlinFloor.get().split('.').take(2).joinToString("."),
    )
    compilerOptions {
        languageVersion.set(floor)
        apiVersion.set(floor)
    }
    coreLibrariesVersion = libs.versions.kotlinFloor.get()
}

dependencies {
    implementation(libs.android.gradle.plugin)
    implementation(libs.kotlin.gradle.plugin)
    implementation(libs.maven.publish.gradle.plugin)
    // The jvm-model-sdk convention builds its javadoc jar with Dokka: a Kotlin
    // source set gives the Java javadoc tool nothing to document.
    implementation(libs.dokka.gradle.plugin)
}

gradlePlugin {
    plugins {
        create("androidLibrary") {
            id = "ai.desertant.android-library"
            implementationClass = "ai.desertant.gradle.AndroidLibraryPlugin"
            displayName = "Desert Ant Android library defaults"
            description = "SDK levels and JVM target shared by every Desert Ant Labs AAR."
        }
        create("modelSdk") {
            id = "ai.desertant.model-sdk"
            implementationClass = "ai.desertant.gradle.ModelSdkPlugin"
            displayName = "Desert Ant model SDK (Android)"
            description = "Android library + publish convention for Desert Ant Labs model SDKs."
        }
        create("jvmModelSdk") {
            id = "ai.desertant.jvm-model-sdk"
            implementationClass = "ai.desertant.gradle.JvmModelSdkPlugin"
            displayName = "Desert Ant model SDK (pure Kotlin, JVM)"
            description = "JVM library + publish convention for pure-Kotlin Desert Ant Labs model SDKs."
        }
        create("publish") {
            id = "ai.desertant.publish"
            implementationClass = "ai.desertant.gradle.CoreLibraryPlugin"
            displayName = "Desert Ant publishing convention"
            description = "Maven Central publishing convention for Desert Ant Labs Android artifacts."
        }
    }
}


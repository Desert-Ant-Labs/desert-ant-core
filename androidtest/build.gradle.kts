// Instrumented-test module that runs the Swift core's Android backends on a
// device/emulator (Tier 2a). It uses :core's HostBridge and DesertAntNative, the
// host classes every SDK installs, loads the cross-compiled
// libCoreAndroidTests.so, and asserts the JNI checks pass. `mise run
// test:android` stages the .so into jniLibs and runs connectedAndroidTest.
plugins {
    id("ai.desertant.android-library")
}

// Filter the test APK without changing which ABIs the SDK modules build.
val compatibilityAbi = providers.gradleProperty("dalCompatibilityAbi").orNull
require(compatibilityAbi == null || compatibilityAbi in listOf("arm64-v8a", "x86_64"))

android {
    namespace = "ai.desertant.core.androidtest"

    defaultConfig {
        testInstrumentationRunner = "ai.desertant.androidtest.HubTestRunner"
        ndk { abiFilters += compatibilityAbi?.let { listOf(it) } ?: listOf("arm64-v8a", "x86_64") }
    }

    // libCoreAndroidTests.so + libc++_shared.so are staged here by the mise task.
    sourceSets["main"].jniLibs.srcDir("src/main/jniLibs")
    // license_vectors.json, from the copy the Swift tests read.
    sourceSets["androidTest"].assets.srcDir("../Tests/UsageTests/Resources")
}

// Discover the same native modules as the production build, including future models.
val nativeModels = rootProject.file("packages").listFiles().orEmpty()
    .filter { it.name.endsWith("-kotlin") && it.resolve("src/main/AndroidManifest.xml").isFile }
    .map { it.name.removeSuffix("-kotlin") }

android.sourceSets["androidTest"].kotlin.directories.add(rootProject.file("androidtest/runner").path)
android.sourceSets["androidTest"].kotlin.directories.add(rootProject.file("Tools/android/tongue").path)
android.sourceSets["androidTest"].assets.srcDir("../Tests/AndroidUnicodeFixtures")
android.sourceSets["androidTest"].assets.srcDir("../Tests/GistTests/Resources")
android.sourceSets["androidTest"].assets.srcDir("../Tests/ToxicTests/Resources")
android.sourceSets["androidTest"].assets.srcDir("../Tests/RedactTests/Resources")
android.sourceSets["androidTest"].assets.srcDir("../packages/tongue-kotlin/src/test/resources")
android.sourceSets["androidTest"].assets.srcDir("../.build/android-unicode/metadata")

dependencies {
    nativeModels.forEach { implementation(project(":$it")) }

    implementation(project(":core"))
    // Exercise the shipping Kotlin APIs and native payload in the same test app.
    implementation(project(":tongue"))

    // CoreBridgeTest reads license_vectors.json. Core keeps the library as an
    // implementation detail, so it is not on this module's classpath otherwise.
    androidTestImplementation(libs.kotlinx.serialization.json)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.kotlinx.coroutines.test)
}

// Instrumented-test module that runs the Swift core's Android backends on a
// device/emulator (Tier 2a). It reuses the shared HostBridge.kt (java.util.regex
// + host JSON parser), loads the cross-compiled libCoreAndroidTests.so, and
// asserts the JNI checks pass. `mise run test-android` builds the .so into
// jniLibs and runs `connectedAndroidTest`.
//
// Plugin/dependency versions are a starting point — align them with the
// consuming SDKs' Android toolchain as needed.
plugins {
    id("com.android.library") version "8.6.0"      // compileSdk 35 needs AGP 8.6.0+ (Gradle 8.7+)
    kotlin("android") version "1.9.24"
    kotlin("plugin.serialization") version "1.9.24"
}

android {
    namespace = "ai.desertant.core.androidtest"
    compileSdk = 35

    defaultConfig {
        minSdk = 31  // CAndroidICU's unorm2_getNFKCInstance is available from API 31
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    // Keep Java and Kotlin on the same JVM target (the JDK is 21; AGP defaults
    // Java to 1.8, which mismatches Kotlin).
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    // Reuse the shared host bridge (regexMatches / jsonParseTree) verbatim.
    sourceSets["main"].java.srcDir("../kotlin/src/main/kotlin")
    // libCoreAndroidTests.so + libc++_shared.so are staged here by the mise task.
    sourceSets["main"].jniLibs.srcDir("src/main/jniLibs")
}

dependencies {
    // HostBridge.kt parses JSON with kotlinx.serialization.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "ai.desertant.tongue.example"
    compileSdk = 35

    defaultConfig {
        applicationId = "ai.desertant.tongue.example"
        // No floor of our own: the SDK is a plain jar using only
        // java.text.Normalizer and java.util.regex, both of which predate API 1.
        // 24 just matches the rest of the org's Android baseline.
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        // No `ndk { abiFilters }` block, unlike EmoAndroidExample: there is no
        // native library here, so the APK is ABI-independent.
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    // The whole SDK. No coroutines dependency, unlike EmoAndroidExample: a
    // detection is synchronous arithmetic over 2 MB of bundled weights, so there
    // is nothing to suspend on and nothing to download.
    implementation("ai.desertant:tongue:1.1.0")
}

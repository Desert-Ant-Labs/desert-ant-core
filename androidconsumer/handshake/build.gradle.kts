plugins {
    id("com.android.application")
}

val sdkVersion = rootDir.resolve("../VERSION").readText().trim()
val legacyVersion = providers.gradleProperty("dalConsumerLegacyVersion").orNull
val scenario = providers.gradleProperty("dalConsumerHandshake").orElse("matching").get()
val handshakeAbi = providers.gradleProperty("dalConsumerHandshakeAbi").orNull

android {
    namespace = "ai.desertant.consumer.handshake"
    compileSdk = 37

    defaultConfig {
        applicationId = "ai.desertant.consumer.handshake"
        minSdk = 24
        targetSdk = 37
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        if (handshakeAbi != null && handshakeAbi != "all") ndk.abiFilters.add(handshakeAbi)
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
    // The explicit platform would normally align even an old model.
    implementation(platform("ai.desertant:bom:$sdkVersion"))
    implementation("ai.desertant:emo")
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.junit)
}

if (scenario == "legacy-core") {
    val forcedVersion = requireNotNull(legacyVersion)
    configurations.configureEach { resolutionStrategy.force("ai.desertant:core:$forcedVersion") }
}

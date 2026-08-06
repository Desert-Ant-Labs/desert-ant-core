import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.net.URI
import java.util.zip.ZipFile

// Publishable Android library for `ai.desertant:core`: the reusable Android host
// side of desert-ant-core's Swift JNI harness (HostBridge.kt), its shared host
// callbacks (DesertAntNative.kt), and the model shell every SDK wraps
// (LoadedModel.kt). Model SDKs used to vendor this verbatim; they now depend on
// this artifact instead.
//
// The AAR also owns the two supported ABI copies of libLiteRt.so. Model AARs
// contain only their own Swift JNI library, so an app using several models gets
// one runtime from this Maven coordinate. `mise run publish:maven` ships it.
// The group, version, and the whole POM come from the root build and the shared
// ai.desertant.publish convention, so nothing is spelled out twice.
//
// The published source is kotlin/src/main/kotlin/ai/desertant/core/HostBridge.kt;
// the androidtest module reuses the same file via a srcDir, so there is one copy.
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("ai.desertant.publish")
}

android {
    namespace = "ai.desertant.core"
    compileSdk = 35

    defaultConfig {
        // API 24 matches the model SDKs. NFKC runs via the host
        // java.text.Normalizer (API 1+), so there is no platform libicu floor.
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

val prepareLiteRt by tasks.registering {
    val version = "2.1.6"
    val output = layout.projectDirectory.dir("src/main/jniLibs")
    inputs.property("litertVersion", version)
    outputs.files(
        output.file("arm64-v8a/libLiteRt.so"),
        output.file("x86_64/libLiteRt.so"),
    )
    doLast {
        val aar = temporaryDir.resolve("litert-$version.aar")
        if (!aar.isFile) {
            URI("https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/litert/$version/litert-$version.aar")
                .toURL().openStream().use { input -> aar.outputStream().use(input::copyTo) }
        }
        ZipFile(aar).use { zip ->
            mapOf("arm64-v8a" to "arm64-v8a", "x86_64" to "x86_64").forEach { (source, abi) ->
                val entry = zip.getEntry("jni/$source/libLiteRt.so")
                    ?: error("LiteRT $version has no $source runtime")
                val destination = output.file("$abi/libLiteRt.so").asFile
                destination.parentFile.mkdirs()
                zip.getInputStream(entry).use { input -> destination.outputStream().use(input::copyTo) }
            }
        }
    }
}

tasks.named("preBuild").configure { dependsOn(prepareLiteRt) }

dependencies {
    // HostBridge.kt parses the Hugging Face tree JSON and emits the binary value
    // tree with kotlinx.serialization; the model SDKs already pull the same lib.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    // LoadedModel uses Dispatchers internally for download and inference.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    testImplementation("junit:junit:4.13.2")
}

desertAntPublish {
    displayName = "Desert Ant Core"
    description =
        "Reusable Android host bridge for Desert Ant Labs on-device model SDKs: the JVM " +
            "counterpart to desert-ant-core's Swift JNI harness (host regex, JSON, NFKC, HTTP, " +
            "and usage persistence)."
}

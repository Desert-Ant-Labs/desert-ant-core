import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Publishable Android library for `ai.desertant:core`: the reusable Android host
// side of desert-ant-core's Swift JNI harness (HostBridge.kt). Model SDKs used
// to vendor this file verbatim; they now depend on this artifact instead.
//
// It is pure Kotlin (no native code, no prebuilt .so), so unlike the model SDKs
// this AAR could build from source anywhere. We still publish it to Maven
// Central for a stable coordinate: `mise run publish-android` runs
// publishToMavenCentral via the vanniktech plugin (Central portal upload,
// validation, in-memory GPG signing; credentials come from the environment,
// usually mise.local.toml). The version is single-sourced here and read by the
// mise check-version/publish tasks.
//
// The published source is kotlin/src/main/kotlin/ai/desertant/core/HostBridge.kt;
// the androidtest module reuses the same file via a srcDir, so there is one copy.
plugins {
    id("com.android.library") version "8.7.3"
    id("org.jetbrains.kotlin.android") version "2.1.21"
    id("com.vanniktech.maven.publish") version "0.34.0"
}

group = "ai.desertant"
version = "0.3.0"

android {
    namespace = "ai.desertant.core"
    compileSdk = 35

    defaultConfig {
        // API 24 matches the model SDKs. NFKC runs via the host
        // java.text.Normalizer (API 1+), so there is no platform libicu floor.
        minSdk = 24
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

dependencies {
    // HostBridge.kt parses the Hugging Face tree JSON and emits the binary value
    // tree with kotlinx.serialization; the model SDKs already pull the same lib.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
}

mavenPublishing {
    publishToMavenCentral()
    // Sign only when a key is provided (CI/release); local publishToMavenLocal
    // stays keyless. ORG_GRADLE_PROJECT_signingInMemoryKey maps to this property.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }
    coordinates("ai.desertant", "core", version.toString())
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = true))
    pom {
        name.set("Desert Ant Core")
        description.set(
            "Reusable Android host bridge for Desert Ant Labs on-device model SDKs: the JVM " +
                "counterpart to desert-ant-core's Swift JNI harness (host regex, JSON, NFKC, HTTP, " +
                "and usage persistence).")
        url.set("https://github.com/Desert-Ant-Labs/desert-ant-core")
        licenses {
            license {
                name.set("Desert Ant Labs Source-Available License 1.0")
                url.set("https://license.desertant.com/1.0")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("desert-ant-labs")
                name.set("Desert Ant Labs")
                email.set("contact@desertant.com")
                url.set("https://desertant.com")
            }
        }
        scm {
            url.set("https://github.com/Desert-Ant-Labs/desert-ant-core")
            connection.set("scm:git:git://github.com/Desert-Ant-Labs/desert-ant-core.git")
            developerConnection.set("scm:git:ssh://git@github.com/Desert-Ant-Labs/desert-ant-core.git")
        }
    }
}

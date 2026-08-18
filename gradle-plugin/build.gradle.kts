import com.vanniktech.maven.publish.GradlePlugin
import com.vanniktech.maven.publish.JavadocJar

// The Android convention plugins for this repo: `ai.desertant.model-sdk` for a
// model's AAR module and `ai.desertant.publish` for ai.desertant:core. The root
// build includes this one (settings.gradle.kts), so the modules here resolve it
// from the checkout; it is also published to Maven Central for consumers outside
// this repo.
plugins {
    kotlin("jvm") version "2.1.21"
    `java-gradle-plugin`
    id("com.vanniktech.maven.publish") version "0.34.0"
}

// One version for the whole repo, single-sourced in VERSION at the repo root
// (this is an included build, so rootDir is gradle-plugin/).
group = "ai.desertant"
version = rootDir.parentFile.resolve("VERSION").readText().trim()

dependencies {
    implementation("com.android.tools.build:gradle:8.7.3")
    implementation("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.21")
    implementation("com.vanniktech:gradle-maven-publish-plugin:0.34.0")
    // The jvm-model-sdk convention builds its javadoc jar with Dokka: a Kotlin
    // source set gives the Java javadoc tool nothing to document.
    implementation("org.jetbrains.dokka:dokka-gradle-plugin:2.0.0")
}

gradlePlugin {
    plugins {
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

mavenPublishing {
    publishToMavenCentral()
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }
    coordinates("ai.desertant", "model-sdk-gradle-plugin", version.toString())
    configure(GradlePlugin(javadocJar = JavadocJar.Empty(), sourcesJar = true))
    pom {
        name.set("Desert Ant model SDK Gradle plugin")
        description.set("Android library + publish conventions for Desert Ant Labs model SDKs.")
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

import com.vanniktech.maven.publish.GradlePlugin
import com.vanniktech.maven.publish.JavadocJar

// Convention plugins for the Desert Ant model SDKs' Android modules
// (ai.desertant.model-sdk + ai.desertant.model-resources). Published to Maven
// Central via vanniktech; consumed with the plugins DSL + mavenCentral() in the
// model repo's settings pluginManagement. Version single-sourced here.
plugins {
    kotlin("jvm") version "2.1.21"
    `java-gradle-plugin`
    id("com.vanniktech.maven.publish") version "0.34.0"
}

group = "ai.desertant"
version = "0.5.2"

dependencies {
    implementation("com.android.tools.build:gradle:8.7.3")
    implementation("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.21")
    implementation("com.vanniktech:gradle-maven-publish-plugin:0.34.0")
}

gradlePlugin {
    plugins {
        create("modelSdk") {
            id = "ai.desertant.model-sdk"
            implementationClass = "ai.desertant.gradle.ModelSdkPlugin"
            displayName = "Desert Ant model SDK (Android)"
            description = "Android library + publish convention for Desert Ant Labs model SDKs."
        }
        create("modelResources") {
            id = "ai.desertant.model-resources"
            implementationClass = "ai.desertant.gradle.ModelResourcesPlugin"
            displayName = "Desert Ant model resources (Android)"
            description = "Bundled-model resources convention for Desert Ant Labs model SDKs."
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

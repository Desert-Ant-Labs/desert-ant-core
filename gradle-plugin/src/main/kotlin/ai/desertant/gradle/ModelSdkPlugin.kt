package ai.desertant.gradle

import com.android.build.api.dsl.LibraryExtension
import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.MavenPublishBaseExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Exec
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

/**
 * `ai.desertant.model-sdk`: the Android library (AAR) convention for a Desert
 * Ant model SDK's `<model>-kotlin` root module. Applies AGP + Kotlin +
 * vanniktech, configures the Android/publish boilerplate, drives the Swift
 * native build (replacing swift-android.gradle.kts), and depends on the shared
 * `ai.desertant:core` host bridge and the model's `:*-tflite-resources` module.
 *
 * The model id comes from the Gradle root project name; only the marketing
 * `description` is model-specific:
 *
 *     plugins { id("ai.desertant.model-sdk") version "X" }
 *     version = "1.2.3"
 *     desertAntSdk { description = "On-device ... for Android." }
 */
abstract class ModelSdkExtension {
    /** POM description for the main artifact (the one genuinely per-model bit). */
    abstract val description: Property<String>
    /** `ai.desertant:core` version to depend on. */
    abstract val coreVersion: Property<String>
}

class ModelSdkPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val ext = project.extensions.create("desertAntSdk", ModelSdkExtension::class.java)
        ext.coreVersion.convention("0.3.0")

        project.pluginManager.apply("com.android.library")
        project.pluginManager.apply("org.jetbrains.kotlin.android")
        project.pluginManager.apply("com.vanniktech.maven.publish")

        val model = project.dalModel
        project.group = "ai.desertant"

        project.extensions.configure(LibraryExtension::class.java) { android ->
            android.namespace = "ai.desertant.$model"
            android.compileSdk = 35
            android.defaultConfig.minSdk = 24 // NFKC via host java.text.Normalizer (API 1+); no platform libicu
            android.defaultConfig.testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
            android.defaultConfig.ndk.abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
            android.buildTypes.getByName("release").isMinifyEnabled = false
            android.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
            android.compileOptions.targetCompatibility = JavaVersion.VERSION_17
        }

        project.tasks.withType(KotlinCompile::class.java).configureEach { t ->
            t.compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
        }

        val deps = project.dependencies
        deps.add("implementation", "ai.desertant:core:${ext.coreVersion.get()}")
        deps.add("implementation", "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
        deps.add("implementation", deps.project(mapOf("path" to ":$model-tflite-resources")))
        deps.add("androidTestImplementation", "androidx.test.ext:junit:1.2.1")
        deps.add("androidTestImplementation", "androidx.test:runner:1.6.2")
        deps.add("androidTestImplementation", "org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")

        // Native build (was swift-android.gradle.kts): `mise run android-natives`
        // builds libDesertAntAndroid.so per ABI into src/main/jniLibs and stages
        // the model into the resources module, before the Android package steps.
        // One native library serves every model (the model is a `modelId` argument
        // to the shared JNI surface, ai.desertant.DesertAntNative), so the .so name
        // does not vary per SDK.
        val repoRoot = project.file("${project.rootDir}/../..")
        val buildNatives = project.tasks.register("buildSwiftNatives", Exec::class.java) { t ->
            t.group = "build"
            t.description = "Builds the Android native libraries into jniLibs (mise run android-natives)."
            t.workingDir = repoRoot
            t.commandLine("mise", "run", "android-natives")
            t.environment("MISE_TRUSTED_CONFIG_PATHS", repoRoot.absolutePath)
            System.getenv("ANDROID_NDK_HOME")?.let { ndk -> t.environment("ANDROID_NDK_HOME", ndk) }
            t.inputs.dir("${project.rootDir}/../../Sources")
            t.inputs.file("${project.rootDir}/../../mise.toml")
            t.outputs.dir("${project.projectDir}/src/main/jniLibs")
            t.outputs.dir("${project.projectDir}/$model-tflite-resources/src/main/resources")
        }
        project.tasks.named("preBuild").configure { it.dependsOn(buildNatives) }

        // vanniktech reads the coordinates from project group/name/version, so no
        // afterEvaluate is needed; the description is wired as a lazy Provider.
        val mp = project.extensions.getByType(MavenPublishBaseExtension::class.java)
        mp.publishToMavenCentral()
        if (project.providers.gradleProperty("signingInMemoryKey").isPresent) mp.signAllPublications()
        mp.configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = true))
        mp.pom { pom -> desertAntPom(pom, model, project.dalProduct, ext.description) }
    }
}

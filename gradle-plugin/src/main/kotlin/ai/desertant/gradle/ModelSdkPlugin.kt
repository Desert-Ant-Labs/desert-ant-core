package ai.desertant.gradle

import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.tasks.Exec
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

/**
 * `ai.desertant.model-sdk`: the Android library (AAR) convention for a model's
 * `packages/<model>-kotlin` module. Applies AGP + Kotlin + the shared publishing
 * convention, drives the Swift JNI cross-compile, and depends on the shared
 * `ai.desertant:core` host bridge.
 *
 * No model ships in the AAR: the SDK downloads its pinned model revision on
 * first use, into the app cache or a directory the app names.
 *
 * The model id is the Gradle project name, so a module is three lines:
 *
 *     plugins { id("ai.desertant.model-sdk") }
 *     desertAntSdk { description = "On-device ... for Android." }
 */
class ModelSdkPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val ext = project.extensions.create("desertAntSdk", DesertAntPublishExtension::class.java)
        val model = project.dalModel
        ext.displayName.convention("Desert Ant ${project.dalProduct}")

        project.pluginManager.apply("com.android.library")
        project.pluginManager.apply("org.jetbrains.kotlin.android")

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

        project.tasks.withType(KotlinCompile::class.java).configureEach { task ->
            task.compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
        }

        val deps = project.dependencies
        // `:core` is a project in the same build, so a model AAR builds from a
        // clean checkout with nothing published yet. The generated POM still
        // carries ai.desertant:core:<version>, because that is core's identity.
        // Core also owns LoadedModel's coroutine runtime, so there is no second
        // direct dependency here.
        deps.add("implementation", project.project(":core"))
        deps.add("androidTestImplementation", "androidx.test.ext:junit:1.2.1")
        deps.add("androidTestImplementation", "androidx.test:runner:1.6.2")
        deps.add("androidTestImplementation", "org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")

        // The Swift JNI library per ABI, built into src/main/jniLibs before the
        // Android packaging steps. ai.desertant:core supplies the one shared
        // LiteRT runtime, so this AAR carries only the model's own library.
        val repoRoot = project.rootDir
        val buildNatives = project.tasks.register("buildSwiftNatives", Exec::class.java) { task ->
            task.group = "build"
            task.description = "Cross-compiles the Android native libraries into jniLibs."
            task.workingDir = repoRoot
            task.commandLine("mise", "run", "build:android-natives", model)
            task.environment("MISE_TRUSTED_CONFIG_PATHS", repoRoot.absolutePath)
            System.getenv("ANDROID_NDK_HOME")?.let { task.environment("ANDROID_NDK_HOME", it) }
            task.inputs.dir(repoRoot.resolve("Sources"))
            task.inputs.dir(repoRoot.resolve("mise-tasks"))
            task.outputs.dir(project.projectDir.resolve("src/main/jniLibs"))
        }
        project.tasks.named("preBuild").configure { it.dependsOn(buildNatives) }

        project.configureDesertAntPublishing(ext)
    }
}

package ai.desertant.gradle

import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.Action
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.Task
import org.gradle.api.services.BuildService
import org.gradle.api.services.BuildServiceParameters
import org.gradle.api.tasks.Exec
import java.io.File

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

        project.configureDesertAntAndroid()

        project.extensions.configure(LibraryExtension::class.java) { android ->
            android.namespace = "ai.desertant.$model"
            android.defaultConfig.testInstrumentationRunner = "ai.desertant.androidtest.HubTestRunner"
            // `kotlin`, not `java`: built-in Kotlin ignores Kotlin sources
            // added to a source set's java directories.
            android.sourceSets.getByName("androidTest").kotlin.directories
                .add(project.rootProject.file("androidtest/runner").path)
            android.defaultConfig.ndk.abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
        }

        val libs = project.libs
        val deps = project.dependencies
        // `:core` is a project in the same build, so a model AAR builds from a
        // clean checkout with nothing published yet. The generated POM still
        // carries ai.desertant:core:<version>, because that is core's identity.
        // Core also owns LoadedModel's coroutine runtime, so there is no second
        // direct dependency here. `api` so an app reaches core's DesertAnt
        // settings through any model it depends on.
        deps.add("api", deps.project(mapOf("path" to ":core")))
        project.exportDesertAntPlatform()
        deps.addProvider("androidTestImplementation", libs.library("androidx-test-ext-junit"))
        deps.addProvider("androidTestImplementation", libs.library("androidx-test-runner"))
        deps.addProvider("androidTestImplementation", libs.library("kotlinx-coroutines-test"))

        // The Swift JNI library per ABI, built into src/main/jniLibs before the
        // Android packaging steps. ai.desertant:core supplies the one shared
        // LiteRT runtime, so this AAR carries only the model's own library.
        val repoRoot = project.rootDir
        val buildNatives = project.tasks.register("buildSwiftNatives", Exec::class.java) { task ->
            task.group = "build"
            task.description = "Cross-compiles the Android native libraries into jniLibs."
            task.workingDir = repoRoot
            // `mise` and the environment are filled in as the task starts
            // (UseCallerEnvironment), not here: the configuration cache stores
            // what an Exec task was configured with and replays it.
            task.commandLine("mise", "run", "build:android-natives", model)
            task.setEnvironment(emptyMap<String, Any>())
            task.doFirst(UseCallerEnvironment(repoRoot.absolutePath))
            // The NDK pin is an input: moving it relinks against another libc++.
            task.inputs.file(repoRoot.resolve("ANDROID_NDK_VERSION"))
            task.inputs.file(repoRoot.resolve("VERSION"))
            // So are the variables build:android-natives reads to pick the ABIs
            // and the toolchain (DAL_ANDROID_ABIS and _API, the DAL_SWIFT_*
            // pins, DAL_LITERT_ANDROID_VERSION). Otherwise switching one, say
            // --abi all after an arm64-only build, finds this task up to date
            // and packages the old natives.
            for (prefix in listOf("DAL_ANDROID_", "DAL_SWIFT_", "DAL_LITERT_")) {
                task.inputs.property(prefix, project.providers.environmentVariablesPrefixedBy(prefix))
            }
            task.inputs.file(repoRoot.resolve("Package.swift"))
            task.inputs.file(repoRoot.resolve("Tools/android/native_size.py"))
            task.inputs.dir(repoRoot.resolve("Sources"))
            task.inputs.dir(repoRoot.resolve("mise-tasks"))
            task.outputs.dir(project.projectDir.resolve("src/main/jniLibs"))
            task.outputs.dir(repoRoot.resolve(".build-android/reports/$model"))
            task.usesService(swiftBuildLock(project))
        }
        project.tasks.named("preBuild").configure { it.dependsOn(buildNatives) }

        project.configureDesertAntPublishing(ext)
    }
}

/**
 * mise, found on the caller's PATH. Since Gradle 9.6 an Exec task looks a bare
 * command up on the daemon's own PATH, which is the PATH of whatever started
 * that daemon (Android Studio, another shell), not the caller's: a daemon
 * started without ~/.local/bin on its PATH fails to start `mise` for every
 * later build. The environment the build sees is still the caller's, so
 * resolve the path from that. Falls back to the bare name, which is what the
 * error then names.
 */
private fun miseExecutable(path: String?): String {
    val names = listOf("mise", "mise.exe")
    return path.orEmpty()
        .split(File.pathSeparator)
        // A relative entry would resolve against the daemon's directory, not the
        // caller's, so only absolute ones count.
        .filter { it.isNotEmpty() && File(it).isAbsolute }
        .flatMap { dir -> names.map { File(dir, it) } }
        .firstOrNull { it.isFile && it.canExecute() }
        ?.path ?: "mise"
}

/**
 * One cross-compile at a time. Every model's build:android-natives shares the
 * `.build-android` scratch directory and the Swift SDK links under it, and two
 * at once fail on those (`ln: ... File exists`) or wait on SwiftPM's lock.
 * The configuration cache runs tasks of different projects in parallel, so
 * nothing else keeps them apart.
 */
abstract class SwiftBuildLock : BuildService<BuildServiceParameters.None>

private fun swiftBuildLock(project: Project) =
    project.gradle.sharedServices.registerIfAbsent("swiftBuildLock", SwiftBuildLock::class.java) {
        it.maxParallelUsages.set(1)
    }

/**
 * Runs build:android-natives in the caller's environment, read as the task
 * starts. The configuration cache stores an Exec task's environment and
 * replays it, so one taken while configuring would cross-compile with stale
 * DAL_* settings, and would write whatever the shell held (HF_TOKEN, the
 * signing key) into the cache entry. It also finds mise on that PATH, so a
 * different PATH does not throw the cache entry away. A class, not a lambda:
 * the configuration cache cannot store a Kotlin lambda.
 */
private class UseCallerEnvironment(private val repoRoot: String) : Action<Task> {
    override fun execute(task: Task) {
        val exec = task as Exec
        val caller = System.getenv()
        exec.setEnvironment(caller + ("MISE_TRUSTED_CONFIG_PATHS" to repoRoot))
        exec.executable = miseExecutable(caller["PATH"])
    }
}

package ai.desertant.gradle

import com.android.build.api.dsl.LibraryExtension
import com.android.build.api.dsl.Lint
import com.android.build.api.variant.LibraryAndroidComponentsExtension
import org.gradle.api.DefaultTask
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

/**
 * `ai.desertant.android-library`: the Android defaults every AAR in this repo
 * shares, so `ai.desertant:core` and the model AARs cannot drift apart on SDK
 * levels or JVM target. `ai.desertant.model-sdk` applies it; core applies it
 * directly, next to `ai.desertant.publish`.
 *
 *     plugins { id("ai.desertant.android-library") }
 *     android { namespace = "..." }
 */
class AndroidLibraryPlugin : Plugin<Project> {
    override fun apply(project: Project) = project.configureDesertAntAndroid()
}

/**
 * AGP and Kotlin, with compileSdk, minSdk, the JVM target and the Kotlin floor
 * from the catalog.
 */
internal fun Project.configureDesertAntAndroid() {
    // AGP 9 compiles Kotlin itself (built-in Kotlin), so there is no
    // org.jetbrains.kotlin.android to apply; the `kotlin` extension below is
    // AGP's.
    pluginManager.apply("com.android.library")

    val jvmTarget = libs.version("jvmTarget")
    extensions.configure(LibraryExtension::class.java) { android ->
        android.compileSdk = libs.version("compileSdk").toInt()
        android.defaultConfig.minSdk = libs.version("minSdk").toInt()
        // Library tests otherwise target minSdk and miss modern app behavior.
        android.testOptions.targetSdk = libs.version("compileSdk").toInt()
        android.buildTypes.getByName("release").isMinifyEnabled = false
        // Java and Kotlin on one target: AGP alone defaults Java to 1.8.
        android.compileOptions.sourceCompatibility = JavaVersion.toVersion(jvmTarget)
        android.compileOptions.targetCompatibility = JavaVersion.toVersion(jvmTarget)
        configureDesertAntLint(android.lint)
    }
    configureSdkVersionSource()
    extensions.configure(KotlinAndroidProjectExtension::class.java) { kotlin ->
        kotlin.compilerOptions.jvmTarget.set(JvmTarget.fromTarget(jvmTarget))
        kotlin.compilerOptions.configureSdkCompiler(this)
        kotlin.coreLibrariesVersion = libs.version("kotlinFloor")
    }
}

// An internal SDK_VERSION constant in the module's namespace, for the runtime
// version handshake. Not BuildConfig, which would add a public class to every AAR.
// One task per variant: AGP points each task's outputDir at its variant's
// generated directory.
private fun Project.configureSdkVersionSource() {
    val sdkVersion = version.toString()
    extensions.getByType(LibraryAndroidComponentsExtension::class.java).onVariants { variant ->
        val name = variant.name.replaceFirstChar { it.uppercase() }
        val task = tasks.register("generate${name}SdkVersion", GenerateSdkVersion::class.java) {
            it.packageName.set(variant.namespace)
            it.sdkVersion.set(sdkVersion)
        }
        variant.sources.kotlin?.addGeneratedSourceDirectory(task, GenerateSdkVersion::outputDir)
    }
}

@CacheableTask
abstract class GenerateSdkVersion : DefaultTask() {
    @get:Input abstract val packageName: Property<String>
    @get:Input abstract val sdkVersion: Property<String>
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun generate() {
        val pkg = packageName.get()
        val dir = outputDir.get().asFile.resolve(pkg.replace('.', '/'))
        dir.mkdirs()
        dir.resolve("SdkVersion.kt").writeText(
            "package $pkg\n\ninternal const val SDK_VERSION = \"${sdkVersion.get()}\"\n",
        )
    }
}

internal fun Project.configureDesertAntLint(lint: Lint) {
    // AutoboxingStateCreation is supplied by Compose's standalone lint checks.
    dependencies.addProvider("lintChecks", libs.library("androidx-compose-runtime-lint"))
    with(lint) {
        abortOnError = true
        checkAllWarnings = true
        checkTestSources = true
        warningsAsErrors = true
        error += "AutoboxingStateCreation"
        // Dependency updates are handled independently of lint.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion")
    }
}

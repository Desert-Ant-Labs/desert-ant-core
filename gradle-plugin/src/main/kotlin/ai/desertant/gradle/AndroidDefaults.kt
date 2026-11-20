package ai.desertant.gradle

import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
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
    }
    extensions.configure(KotlinAndroidProjectExtension::class.java) { kotlin ->
        kotlin.compilerOptions.jvmTarget.set(JvmTarget.fromTarget(jvmTarget))
        kotlin.compilerOptions.useKotlinFloor(this)
        kotlin.coreLibrariesVersion = libs.version("kotlinFloor")
    }
}

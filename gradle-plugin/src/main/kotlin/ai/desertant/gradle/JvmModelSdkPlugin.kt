package ai.desertant.gradle

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.tasks.JavaExec
import org.gradle.api.tasks.testing.Test
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension

/**
 * `ai.desertant.jvm-model-sdk`: the convention for a pure-Kotlin model module —
 * a plain JVM jar rather than an AAR, because the model is a direct Kotlin port
 * with no native library, no LiteRT and no Android-only surface. The same
 * bytecode serves Android and the JVM, so the module deliberately takes no
 * `ai.desertant:core` dependency (core is an AAR, which a JVM consumer cannot
 * resolve) and adds nothing beyond kotlin-stdlib to the POM. Tongue is the
 * first of these; the Android-AAR shape stays `ai.desertant.model-sdk`.
 *
 * The model id is the Gradle project name, so a module is three lines:
 *
 *     plugins { id("ai.desertant.jvm-model-sdk") }
 *     desertAntSdk { description = "On-device ... in pure Kotlin." }
 */
class JvmModelSdkPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val ext = project.extensions.create("desertAntSdk", DesertAntPublishExtension::class.java)
        ext.displayName.convention("Desert Ant ${project.dalProduct}")

        project.pluginManager.apply("org.jetbrains.kotlin.jvm")
        project.pluginManager.apply("java-library")
        project.pluginManager.apply("org.jetbrains.dokka")

        project.extensions.configure(KotlinJvmProjectExtension::class.java) { kotlin ->
            kotlin.jvmToolchain(17)
            kotlin.explicitApi()
        }

        project.dependencies.add("testImplementation", "org.jetbrains.kotlin:kotlin-test")

        // This repo's own runs must not count as billable devices; consumers
        // get usage reporting on by default.
        project.tasks.withType(Test::class.java).configureEach { it.environment("DAL_USAGE_DISABLED", "1") }
        project.tasks.withType(JavaExec::class.java).configureEach { it.environment("DAL_USAGE_DISABLED", "1") }

        project.configureDesertAntPublishing(ext, jvm = true)
    }
}

package ai.desertant.gradle

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.tasks.JavaExec
import org.gradle.api.tasks.testing.Test
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension

/**
 * `ai.desertant.jvm-model-sdk`: the convention for a pure-Kotlin model module:
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

        project.reportTestsToLocalIngest()

        project.configureDesertAntPublishing(ext, jvm = true)
    }
}

/**
 * Inside this repo only: test and exec tasks report to a closed local port under a usage namespace of their own, with the
 * developer's key and device id removed and java.util.prefs pointed at the build directory where the platform honors it.
 */
internal fun org.gradle.api.Project.reportTestsToLocalIngest() {
    if (repoTestRunnerDir == null) return
    val prefsRoot = layout.buildDirectory.dir("tmp/java-prefs").get().asFile
    tasks.withType(Test::class.java).configureEach { it.reportToLocalIngest(prefsRoot) }
    tasks.withType(JavaExec::class.java).configureEach { it.reportToLocalIngest(prefsRoot) }
}

private fun org.gradle.process.JavaForkOptions.reportToLocalIngest(prefsRoot: java.io.File) {
    setEnvironment(environment.filterKeys { key -> key !in INHERITED_USAGE_SETTINGS })
    environment("DAL_APP_ID", "ai.desertant.test.${java.util.UUID.randomUUID()}")
    systemProperty("DAL_INGEST_ENDPOINT", LOCAL_INGEST_ENDPOINT)
    systemProperty("java.util.prefs.userRoot", prefsRoot.absolutePath)
}

/** A shell's usage settings, which must never reach this repo's own test processes. */
private val INHERITED_USAGE_SETTINGS = setOf("DAL_INGEST_ENDPOINT", "DAL_APP_ID", "DAL_API_KEY", "DAL_DEVICE_ID")

/** A closed local port for test tasks. */
private const val LOCAL_INGEST_ENDPOINT = "http://127.0.0.1:1/ingest"

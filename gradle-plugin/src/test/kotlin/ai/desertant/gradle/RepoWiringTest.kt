package ai.desertant.gradle

import com.android.build.gradle.LibraryExtension
import org.gradle.testfixtures.ProjectBuilder
import org.gradle.testkit.runner.GradleRunner
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The repo-only test wiring applies inside this repo and never in an outside build that uses the published plugins. */
class RepoWiringTest {
    private fun tempDir(insideRepo: Boolean): File {
        val dir = Files.createTempDirectory("dal-plugin").toFile()
        if (insideRepo) dir.resolve("kotlin/src/androidTestRunner/kotlin").mkdirs()
        return dir
    }

    private fun modelModule(insideRepo: Boolean): LibraryExtension {
        val root = ProjectBuilder.builder().withProjectDir(tempDir(insideRepo)).build()
        ProjectBuilder.builder().withName("core").withParent(root).build()
        val emo = ProjectBuilder.builder().withName("emo").withParent(root).build()
        emo.pluginManager.apply(ModelSdkPlugin::class.java)
        return emo.extensions.getByType(LibraryExtension::class.java)
    }

    @Test fun anOutsideBuildKeepsTheStandardRunnerAndNoRepoSources() {
        val android = modelModule(insideRepo = false)
        assertEquals("androidx.test.runner.AndroidJUnitRunner", android.defaultConfig.testInstrumentationRunner)
        assertFalse(android.sourceSets.getByName("androidTest").java.srcDirs.any { it.path.contains("androidTestRunner") })
    }

    @Test fun anOutsideBuildKeepsARunnerOfItsOwn() {
        val android = modelModule(insideRepo = false)
        android.defaultConfig.testInstrumentationRunner = "com.acme.AcmeRunner"
        assertEquals("com.acme.AcmeRunner", android.defaultConfig.testInstrumentationRunner)
    }

    @Test fun thisRepoUsesTheLocalIngestRunner() {
        val android = modelModule(insideRepo = true)
        assertEquals("ai.desertant.testing.LocalIngestRunner", android.defaultConfig.testInstrumentationRunner)
        assertTrue(android.sourceSets.getByName("androidTest").java.srcDirs.any { it.path.contains("androidTestRunner") })
    }

    /** Applies the published JVM plugin to a real build and reads what its Test and JavaExec tasks carry. */
    private fun jvmTaskWiring(insideRepo: Boolean): Map<String, String> {
        val dir = tempDir(insideRepo)
        dir.resolve("settings.gradle.kts").writeText("rootProject.name = \"tongue\"\n")
        dir.resolve("build.gradle.kts").writeText(
            """
            plugins { id("ai.desertant.jvm-model-sdk") }
            desertAntSdk { description = "probe" }
            tasks.register<JavaExec>("probeExec") { mainClass.set("Probe") }
            tasks.register("probe") {
                doLast {
                    val test = tasks.named<Test>("test").get()
                    val exec = tasks.named<JavaExec>("probeExec").get()
                    println("testProperty=" + test.systemProperties["DAL_INGEST_ENDPOINT"])
                    println("testEnvironment=" + test.environment["DAL_INGEST_ENDPOINT"])
                    println("execProperty=" + exec.systemProperties["DAL_INGEST_ENDPOINT"])
                    println("execEnvironment=" + exec.environment["DAL_INGEST_ENDPOINT"])
                    for ((name, task) in listOf("test" to test, "exec" to exec)) {
                        for (key in listOf("DAL_APP_ID", "DAL_API_KEY", "DAL_DEVICE_ID")) println("${'$'}name.${'$'}key=" + task.environment[key])
                        println("${'$'}name.prefsRoot=" + task.systemProperties["java.util.prefs.userRoot"])
                    }
                }
            }
            """.trimIndent(),
        )
        val result = GradleRunner.create()
            .withProjectDir(dir)
            .withPluginClasspath()
            .withEnvironment(System.getenv() + INHERITED)
            .withArguments("probe", "-q")
            .build()
        return result.output.lines().filter { it.contains('=') }.associate { it.substringBefore('=') to it.substringAfter('=') }
    }

    @Test fun thisRepoSendsJvmTestAndExecUsageToALocalPort() {
        val wiring = jvmTaskWiring(insideRepo = true)
        assertEquals("http://127.0.0.1:1/ingest", wiring["testProperty"])
        assertEquals("http://127.0.0.1:1/ingest", wiring["execProperty"])
        assertEquals("null", wiring["testEnvironment"], "the inherited endpoint was not stripped from Test")
        assertEquals("null", wiring["execEnvironment"], "the inherited endpoint was not stripped from JavaExec")
        for (task in listOf("test", "exec")) {
            assertTrue(wiring["$task.DAL_APP_ID"]!!.startsWith("ai.desertant.test."), "$task has no test namespace")
            assertEquals("null", wiring["$task.DAL_API_KEY"], "$task kept the shell's key")
            assertEquals("null", wiring["$task.DAL_DEVICE_ID"], "$task kept the shell's device id")
            assertTrue(wiring["$task.prefsRoot"]!!.endsWith("java-prefs"), "$task prefs root is not the build directory")
        }
    }

    @Test fun anOutsideJvmBuildIsLeftAlone() {
        val wiring = jvmTaskWiring(insideRepo = false)
        assertEquals("null", wiring["testProperty"])
        assertEquals("null", wiring["execProperty"])
        assertEquals("http://inherited.example/ingest", wiring["testEnvironment"])
        assertEquals("http://inherited.example/ingest", wiring["execEnvironment"])
        for (task in listOf("test", "exec")) {
            assertEquals("com.acme.app", wiring["$task.DAL_APP_ID"])
            assertEquals("pk_acme", wiring["$task.DAL_API_KEY"])
            assertEquals("acme-device", wiring["$task.DAL_DEVICE_ID"])
            assertEquals("null", wiring["$task.prefsRoot"])
        }
    }

    private companion object {
        /** A developer's shell identity, as a test JVM would inherit it. */
        val INHERITED = mapOf(
            "DAL_INGEST_ENDPOINT" to "http://inherited.example/ingest",
            "DAL_APP_ID" to "com.acme.app",
            "DAL_API_KEY" to "pk_acme",
            "DAL_DEVICE_ID" to "acme-device",
        )
    }
}

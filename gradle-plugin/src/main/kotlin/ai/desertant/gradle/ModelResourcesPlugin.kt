package ai.desertant.gradle

import com.vanniktech.maven.publish.JavaLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.MavenPublishBaseExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.provider.ListProperty
import org.gradle.jvm.tasks.Jar

/**
 * `ai.desertant.model-resources`: the optional bundled-model module
 * (`<model>-tflite-resources`) that packages the LiteRT model files staged by
 * `mise run android-natives` as classpath resources. Apps opt into offline use
 * by depending on `ai.desertant:<model>-tflite-resources`.
 *
 *     plugins { id("ai.desertant.model-resources") version "X" }
 *     version = "1.2.3"
 *     desertAntResources { tfliteFiles = listOf("emo.tflite", "emo_meta.json", "emo_tokenizer.bin") }
 */
abstract class ModelResourcesExtension {
    /** The staged model files this module must contain before it can be jarred. */
    abstract val tfliteFiles: ListProperty<String>
}

class ModelResourcesPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val ext = project.extensions.create("desertAntResources", ModelResourcesExtension::class.java)

        project.pluginManager.apply("java-library")
        project.pluginManager.apply("com.vanniktech.maven.publish")

        val model = project.dalModel
        project.group = "ai.desertant"

        // The model files are staged (gitignored) by the root project's Swift
        // build task; depend on it so a fresh checkout cannot publish an empty
        // model jar, and fail fast if staging left files missing.
        val stageModel = project.rootProject.tasks.named("buildSwiftNatives")
        project.tasks.named("processResources").configure { it.dependsOn(stageModel) }
        project.tasks.withType(Jar::class.java).matching { it.name == "sourcesJar" }.configureEach { jar ->
            jar.dependsOn(stageModel)
            // The model binaries are the main jar's content; keep the sources jar
            // (required by Maven Central) minimal instead of duplicating them.
            jar.exclude("*.tflite", "*.json", "*.bin")
        }
        project.tasks.named("jar", Jar::class.java).configure { jar ->
            jar.doFirst { _ ->
                val resources = project.file("src/main/resources")
                val required = ext.tfliteFiles.get()
                val missing = required.filterNot { resources.resolve(it).isFile }
                check(missing.isEmpty()) {
                    "model files missing from $resources: $missing (run `mise run android-natives`)"
                }
            }
        }

        // vanniktech reads the coordinates from project group/name/version.
        val mp = project.extensions.getByType(MavenPublishBaseExtension::class.java)
        mp.publishToMavenCentral()
        if (project.providers.gradleProperty("signingInMemoryKey").isPresent) mp.signAllPublications()
        mp.configure(JavaLibrary(javadocJar = JavadocJar.Empty(), sourcesJar = true))
        mp.pom { pom ->
            desertAntPom(
                pom,
                model,
                "${project.dalProduct} LiteRT resources",
                project.provider { "Opt-in bundled on-device ${project.dalProduct} model files for Android (no network at runtime)." },
            )
        }
    }
}

package ai.desertant.gradle

import org.gradle.api.Plugin
import org.gradle.api.Project

/**
 * `ai.desertant.publish`: the publishing half of the model-SDK convention, for
 * `ai.desertant:core` and `ai.desertant:bom`.
 *
 *     plugins { id("ai.desertant.publish") }
 *     desertAntPublish { displayName = "..."; description = "..." }
 */
class CoreLibraryPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val ext = project.extensions.create("desertAntPublish", DesertAntPublishExtension::class.java)
        if (project.pluginManager.hasPlugin("java-platform")) {
            val modules = project.rootProject.subprojects.filter {
                it.name == "core" || it.projectDir.parentFile.name == "packages"
            }
            val deps = project.dependencies
            modules.forEach { deps.constraints.add("api", deps.project(mapOf("path" to it.path))) }
            val aars = modules.filter { it.file("src/main/AndroidManifest.xml").isFile }.map { it.name }.toSet()
            project.configureDesertAntPublishing(ext, managedAars = aars)
        } else {
            project.exportDesertAntPlatform()
            project.configureDesertAntPublishing(ext)
        }
    }
}

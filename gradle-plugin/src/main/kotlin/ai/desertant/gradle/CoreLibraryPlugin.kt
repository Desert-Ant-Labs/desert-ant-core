package ai.desertant.gradle

import org.gradle.api.Plugin
import org.gradle.api.Project

/**
 * `ai.desertant.publish`: the publishing half of the model-SDK convention, for
 * an Android library that is not a model - today just `ai.desertant:core`. It
 * exists so the ~40 lines of source-available POM boilerplate are written once
 * and both artifacts provably ship the same license and SCM metadata.
 *
 *     plugins { id("ai.desertant.publish") }
 *     desertAntPublish { displayName = "..."; description = "..." }
 */
class CoreLibraryPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val ext = project.extensions.create("desertAntPublish", DesertAntPublishExtension::class.java)
        project.configureDesertAntPublishing(ext)
    }
}

package ai.desertant.gradle

import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.MavenPublishBaseExtension
import org.gradle.api.Project
import org.gradle.api.provider.Property

/** Every Android artifact in this repo ships from the one desert-ant-core repo,
 *  so the POM's url/scm are the same for all of them. */
internal const val REPO_URL = "https://github.com/Desert-Ant-Labs/desert-ant-core"

/** The model id: the Gradle project name (`:emo` from packages/emo-kotlin). */
internal val Project.dalModel: String
    get() = name

internal val Project.dalProduct: String
    get() = dalModel.replaceFirstChar { it.uppercase() }

/** Shared knobs for the two publishable Android artifact shapes. */
abstract class DesertAntPublishExtension {
    /** POM display name, e.g. "Desert Ant Emo". */
    abstract val displayName: Property<String>

    /** POM description for the main artifact (the genuinely per-artifact bit). */
    abstract val description: Property<String>
}

/**
 * Apply the Maven publishing convention every Desert Ant Android artifact
 * shares: the Central portal upload, signing only when a key is supplied (so
 * `publishToMavenLocal` stays keyless), a single release variant with sources
 * and javadoc, and the source-available license/developer/SCM POM.
 *
 * Coordinates come from the project's group/name/version, which the root build
 * sets from VERSION - so they are never spelled out in a build script.
 */
internal fun Project.configureDesertAntPublishing(ext: DesertAntPublishExtension) {
    pluginManager.apply("com.vanniktech.maven.publish")
    val publishing = extensions.getByType(MavenPublishBaseExtension::class.java)
    publishing.publishToMavenCentral()
    // ORG_GRADLE_PROJECT_signingInMemoryKey maps to this property in CI.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) publishing.signAllPublications()
    publishing.configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = true))
    publishing.pom { pom ->
        pom.name.set(ext.displayName)
        pom.description.set(ext.description)
        pom.url.set(REPO_URL)
        pom.licenses { spec ->
            spec.license { license ->
                license.name.set("Desert Ant Labs Source-Available License 1.0")
                license.url.set("https://license.desertant.com/1.0")
                license.distribution.set("repo")
            }
        }
        pom.developers { spec ->
            spec.developer { developer ->
                developer.id.set("desert-ant-labs")
                developer.name.set("Desert Ant Labs")
                developer.email.set("contact@desertant.com")
                developer.url.set("https://desertant.com")
            }
        }
        pom.scm { scm ->
            scm.url.set(REPO_URL)
            scm.connection.set("scm:git:git://github.com/Desert-Ant-Labs/desert-ant-core.git")
            scm.developerConnection.set("scm:git:ssh://git@github.com/Desert-Ant-Labs/desert-ant-core.git")
        }
    }
}

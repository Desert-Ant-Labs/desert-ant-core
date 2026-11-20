package ai.desertant.gradle

import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.KotlinJvm
import com.vanniktech.maven.publish.MavenPublishBaseExtension
import com.vanniktech.maven.publish.SourcesJar
import org.gradle.api.GradleException
import org.gradle.api.Project
import org.gradle.api.artifacts.MinimalExternalModuleDependency
import org.gradle.api.artifacts.VersionCatalog
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.api.credentials.PasswordCredentials
import org.gradle.api.provider.Property
import org.gradle.api.provider.Provider
import org.gradle.api.publish.PublishingExtension
import org.jetbrains.kotlin.gradle.dsl.KotlinCommonCompilerOptions
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

/** Every Android artifact in this repo ships from the one desert-ant-core repo,
 *  so the POM's url/scm are the same for all of them. */
internal const val REPO_URL = "https://github.com/Desert-Ant-Labs/desert-ant-core"

/** The model id: the Gradle project name (`:emo` from packages/emo-kotlin). */
internal val Project.dalModel: String
    get() = name

internal val Project.dalProduct: String
    get() = dalModel.replaceFirstChar { it.uppercase() }

/** The build's version catalog, gradle/libs.versions.toml at the repo root. */
internal val Project.libs: VersionCatalog
    get() = extensions.getByType(VersionCatalogsExtension::class.java).named("libs")

internal fun VersionCatalog.version(alias: String): String =
    findVersion(alias).orElseThrow { GradleException("gradle/libs.versions.toml has no version '$alias'") }
        .requiredVersion

internal fun VersionCatalog.library(alias: String): Provider<MinimalExternalModuleDependency> =
    findLibrary(alias).orElseThrow { GradleException("gradle/libs.versions.toml has no library '$alias'") }

/**
 * Build at the Kotlin floor's language and API version (kotlinFloor in the
 * catalog), whatever compiler runs. A newer language version would let SDK code
 * use features an app on the floor cannot read, and a newer API version would
 * let it call stdlib functions the floor's stdlib does not have. The stdlib
 * itself is pinned by `coreLibrariesVersion` next to each call. Deprecated API
 * usage fails compilation so the SDK can migrate before the API is removed.
 */
internal fun KotlinCommonCompilerOptions.configureSdkCompiler(project: Project) {
    val floor = KotlinVersion.fromVersion(project.libs.version("kotlinFloor").split('.').take(2).joinToString("."))
    languageVersion.set(floor)
    apiVersion.set(floor)
    freeCompilerArgs.add("-Xwarning-level=DEPRECATION:error")
}

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
 *
 * `-PdalPublishDocs=false` leaves the javadoc and sources jars out. Only
 * check:android-consumer passes it: its fixture compiles against the AARs and
 * jars and never reads the docs, which cost a javadoc run per AAR and a Dokka
 * run for Tongue. Central rejects a deployment without them, so publish:maven
 * never sets it.
 */
internal fun Project.configureDesertAntPublishing(ext: DesertAntPublishExtension, jvm: Boolean = false) {
    pluginManager.apply("com.vanniktech.maven.publish")
    val publishing = extensions.getByType(MavenPublishBaseExtension::class.java)
    publishing.publishToMavenCentral()
    extensions.getByType(PublishingExtension::class.java).repositories.maven { repo ->
        repo.name = "GitHubPackages"
        repo.setUrl("https://maven.pkg.github.com/${System.getenv("GITHUB_REPOSITORY")}")
        repo.credentials(PasswordCredentials::class.java)
    }
    // ORG_GRADLE_PROJECT_signingInMemoryKey maps to this property in CI.
    if (!providers.gradleProperty("signingInMemoryKey").orNull.isNullOrEmpty()) publishing.signAllPublications()
    val docs = providers.gradleProperty("dalPublishDocs").orNull != "false"
    val sourcesJar = if (docs) SourcesJar.Sources() else SourcesJar.None()
    if (jvm) {
        // Dokka, not the `javadoc` task: a Kotlin source set has no Java
        // sources, so the javadoc tool would ship a jar holding only a manifest.
        val javadocJar = if (docs) JavadocJar.Dokka("dokkaGeneratePublicationHtml") else JavadocJar.None()
        publishing.configure(KotlinJvm(javadocJar = javadocJar, sourcesJar = sourcesJar))
    } else {
        // AGP's own javadoc jar for the release variant (JavadocJar.Javadoc), as
        // before. With the plugin's default, Empty, Central would get a jar
        // with nothing in it.
        val javadocJar = if (docs) JavadocJar.Javadoc() else JavadocJar.None()
        publishing.configure(AndroidSingleVariantLibrary(javadocJar = javadocJar, sourcesJar = sourcesJar, variant = "release"))
    }
    publishing.pom { pom ->
        pom.name.set(ext.displayName)
        pom.description.set(ext.description)
        pom.url.set(REPO_URL)
        pom.licenses { spec ->
            spec.license { license ->
                license.name.set("Desert Ant Labs Source-Available License")
                license.url.set("https://license.desertant.com/")
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

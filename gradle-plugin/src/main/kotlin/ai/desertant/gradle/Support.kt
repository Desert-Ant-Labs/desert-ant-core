package ai.desertant.gradle

import org.gradle.api.Project
import org.gradle.api.provider.Provider
import org.gradle.api.publish.maven.MavenPom

/** The model id derived from the Gradle root project name (settings.gradle.kts
 *  `rootProject.name = "emo"`), and the capitalized product name. */
internal val Project.dalModel: String
    get() = rootProject.name

internal val Project.dalProduct: String
    get() = dalModel.replaceFirstChar { it.uppercase() }

/** Apply the shared Maven POM every Desert Ant model artifact publishes: the
 *  source-available license, the org developer, and the model repo's SCM/URL. */
internal fun desertAntPom(pom: MavenPom, model: String, displayName: String, description: Provider<String>) {
    val repoUrl = "https://github.com/Desert-Ant-Labs/$model"
    pom.name.set(displayName)
    pom.description.set(description)
    pom.url.set(repoUrl)
    pom.licenses { spec ->
        spec.license { l ->
            l.name.set("Desert Ant Labs Source-Available License 1.0")
            l.url.set("https://license.desertant.com/1.0")
            l.distribution.set("repo")
        }
    }
    pom.developers { spec ->
        spec.developer { d ->
            d.id.set("desert-ant-labs")
            d.name.set("Desert Ant Labs")
            d.email.set("contact@desertant.com")
            d.url.set("https://desertant.com")
        }
    }
    pom.scm { s ->
        s.url.set(repoUrl)
        s.connection.set("scm:git:git://github.com/Desert-Ant-Labs/$model.git")
        s.developerConnection.set("scm:git:ssh://git@github.com/Desert-Ant-Labs/$model.git")
    }
}

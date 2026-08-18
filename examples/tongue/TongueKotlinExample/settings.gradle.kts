dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // Before ai.desertant:tongue is on Central at this version,
        // `./gradlew :tongue:publishToMavenLocal` at the repo root puts it in
        // ~/.m2 and this resolves it from there. Harmless afterwards: a
        // released version is found either way.
        mavenLocal()
        mavenCentral()
    }
}
rootProject.name = "tongue-kotlin-example"

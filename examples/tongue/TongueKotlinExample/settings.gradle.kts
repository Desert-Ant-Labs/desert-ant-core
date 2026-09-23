dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // For a version not yet on Central, `./gradlew :tongue:publishToMavenLocal`
        // at the repo root puts it in ~/.m2 and this resolves it from there. A
        // released version is found either way.
        mavenLocal()
        mavenCentral()
    }
}
rootProject.name = "tongue-kotlin-example"

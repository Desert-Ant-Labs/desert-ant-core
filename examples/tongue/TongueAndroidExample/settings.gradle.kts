pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // For a version not yet on Central, `./gradlew :tongue:publishToMavenLocal`
        // at the repo root puts it in ~/.m2 and this resolves it from there. A
        // released version is found either way.
        // Not `mise run publish-android` - that publishes to Maven Central for
        // real when credentials are present. See this example's README.
        mavenLocal()
        google()
        mavenCentral()
    }
}

rootProject.name = "TongueAndroidExample"
include(":app")

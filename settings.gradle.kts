// One Gradle build for every publishable Android artifact in this repo:
// `ai.desertant:core` (kotlin/) and one AAR per model (packages/<model>-kotlin).
//
// The model modules used to be separate builds that resolved the convention
// plugin and `ai.desertant:core` from Maven Central, so they could not be built
// at all until core had been published - which is why releasing needed a job
// that sat waiting for Central to catch up. Here the plugin is an included build
// and core is a project in this one, so a model AAR builds from a clean checkout
// and a release is a single ordered Gradle invocation.
pluginManagement {
    includeBuild("gradle-plugin")
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "desert-ant-core"

include("core")
project(":core").projectDir = file("kotlin")

// packages/<model>-kotlin becomes :<model>, published as ai.desertant:<model>.
// Discovered, not listed: adding a model is adding the directory.
file("packages").listFiles().orEmpty()
    .filter { it.isDirectory && it.name.endsWith("-kotlin") && it.resolve("build.gradle.kts").isFile }
    .sortedBy { it.name }
    .forEach { dir ->
        val model = dir.name.removeSuffix("-kotlin")
        include(model)
        project(":$model").projectDir = dir
    }

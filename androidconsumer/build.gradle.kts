// AGP from the SDK build's catalog. Kotlin's version is the check's choice
// (settings.gradle.kts), so it is not declared here.
//
// The Kotlin plugin goes on this classpath next to AGP so the app compiles with
// it too: AGP 9's built-in Kotlin uses whichever Kotlin Gradle plugin is loaded
// here, and on its own brings an older one (2.2.10 for AGP 9.5).
plugins {
    alias(libs.plugins.android.application) apply false
    id("org.jetbrains.kotlin.jvm") apply false
}

// The floor run proves its compiler instead of assuming it: if anything moved
// the Kotlin Gradle plugin off the requested version (AGP's dependency, a
// catalog edit), stop here rather than report the wrong compiler as passing.
val requestedKotlin = providers.gradleProperty("dalConsumerKotlin").get()
val loadedKotlin = org.jetbrains.kotlin.gradle.plugin.getKotlinPluginVersion(logger)
check(loadedKotlin == requestedKotlin) {
    "asked for Kotlin $requestedKotlin, but the build loaded Kotlin Gradle plugin $loadedKotlin"
}

// And the stdlib: the compiler adds kotlin-stdlib at its own version, so if the
// resolved one is any newer, an SDK's POM raised it (a kotlinx bump, a new
// dependency). The compiler would still read the newer metadata, so without
// this the floor run would pass on a floor apps no longer have.
subprojects {
    val classpath = if (name == "app") "debugRuntimeClasspath" else "runtimeClasspath"
    tasks.register("checkKotlinStdlib") {
        val root = configurations.named(classpath).flatMap { it.incoming.resolutionResult.rootComponent }
        val requested = requestedKotlin
        doLast {
            val seen = mutableSetOf<ResolvedComponentResult>()
            fun walk(component: ResolvedComponentResult): Sequence<ResolvedComponentResult> =
                if (!seen.add(component)) emptySequence()
                else sequenceOf(component) + component.dependencies.asSequence()
                    .filterIsInstance<ResolvedDependencyResult>()
                    .flatMap { walk(it.selected) }
            val stdlib = walk(root.get())
                .mapNotNull { it.id as? ModuleComponentIdentifier }
                .filter { it.group == "org.jetbrains.kotlin" && it.module == "kotlin-stdlib" }
                .map { it.version }
                .toSet()
            check(stdlib == setOf(requested)) {
                "$path resolved kotlin-stdlib ${stdlib.ifEmpty { setOf("(none)") }.joinToString()}, " +
                    "but this run is Kotlin $requested: an SDK's dependencies raised it"
            }
        }
    }
}

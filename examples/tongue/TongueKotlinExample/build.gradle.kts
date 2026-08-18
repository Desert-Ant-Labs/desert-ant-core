// Runnable console example. Resolves ai.desertant:tongue from mavenLocal (see
// settings.gradle.kts) or Central, so it exercises the real published artifact
// rather than the source tree.
plugins {
    kotlin("jvm") version "2.1.0"
    application
}
kotlin { jvmToolchain(17) }
dependencies { implementation("ai.desertant:tongue:1.1.0") }
application { mainClass.set("MainKt") }

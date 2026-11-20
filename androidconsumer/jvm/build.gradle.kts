// A plain JVM consumer of the pure-Kotlin SDKs (a module without an
// AndroidManifest.xml ships a jar, not an AAR), on JDK 17.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

val sdkVersion = rootDir.resolve("../VERSION").readText().trim()

kotlin {
    jvmToolchain(17)
    compilerOptions { freeCompilerArgs.add("-Xwarning-level=DEPRECATION:error") }
}

// The pure-Kotlin SDKs, as check:android-consumer lists them.
val models = providers.gradleProperty("dalConsumerJvmModels").orNull
    ?: error("pass -PdalConsumerJvmModels=<model,...>, or run `mise run check:android-consumer`")

dependencies {
    models.split(',').filter { it.isNotEmpty() }
        .forEach { implementation("ai.desertant:$it:$sdkVersion") }
}

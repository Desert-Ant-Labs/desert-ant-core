// A plain JVM consumer of the pure-Kotlin SDKs (a module without an
// AndroidManifest.xml ships a jar, not an AAR), on JDK 17.
plugins {
    id("org.jetbrains.kotlin.jvm")
    application
}

val sdkVersion = rootDir.resolve("../VERSION").readText().trim()

kotlin {
    jvmToolchain(17)
    compilerOptions { freeCompilerArgs.add("-Xwarning-level=DEPRECATION:error") }
}
application { mainClass.set("ai.desertant.consumer.TongueKt") }

// Tongue asks for a license when it loads. Nothing listens on this port, and its license file stays in the build directory.
tasks.named<JavaExec>("run") {
    environment("DAL_LICENSE_ENDPOINT", "http://127.0.0.1:9/api/v1")
    environment("DAL_STATE_DIR", layout.buildDirectory.dir("license-state").get().asFile.path)
}

// The pure-Kotlin SDKs, as check:android-consumer lists them.
val models = providers.gradleProperty("dalConsumerJvmModels").orNull
    ?: error("pass -PdalConsumerJvmModels=<model,...>, or run `mise run check:android-consumer`")

dependencies {
    implementation(platform("ai.desertant:bom:$sdkVersion"))
    models.split(',').filter { it.isNotEmpty() }
        .forEach { implementation("ai.desertant:$it") }
}

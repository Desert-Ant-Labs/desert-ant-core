import java.net.URI
import java.util.zip.ZipFile

// Publishable Android library for `ai.desertant:core`: the reusable Android host
// side of desert-ant-core's Swift JNI harness (HostBridge.kt), its shared host
// callbacks (DesertAntNative.kt), and the model shell every SDK wraps
// (LoadedModel.kt).
//
// The AAR also owns the two supported ABI copies of libLiteRt.so. Model AARs
// contain only their own Swift JNI library, so an app using several models gets
// one runtime from this Maven coordinate. `mise run publish:maven` ships it.
// The group, version, and the whole POM come from the root build and the shared
// ai.desertant.publish convention, so nothing is spelled out twice.
//
// The :androidtest harness depends on this module, so the on-device checks run
// against the same HostBridge.kt and DesertAntNative.kt that ship.
plugins {
    id("ai.desertant.android-library")
    id("ai.desertant.publish")
}

android {
    namespace = "ai.desertant.core"
    defaultConfig { consumerProguardFiles("consumer-rules.pro") }
    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            // Robolectric needs access to these JDK internals on Java 17+.
            it.jvmArgs(
                "--add-opens=java.base/java.lang=ALL-UNNAMED",
                "--add-opens=java.base/java.util=ALL-UNNAMED",
                "--add-opens=java.base/java.io=ALL-UNNAMED",
                "--add-opens=java.base/java.net=ALL-UNNAMED",
                "--add-opens=java.base/java.security=ALL-UNNAMED",
                "--add-opens=java.base/java.text=ALL-UNNAMED",
                "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED",
                "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED",
                "--add-opens=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
            )
        }
    }
}

val prepareLiteRt = tasks.register("prepareLiteRt") {
    val version = "2.3.2"
    // The runtime proper (litert AAR), plus the OpenCL/OpenGL GPU accelerator
    // the runtime dlopens when a session asks for kLiteRtHwAcceleratorGpu
    // (litert-gpu AAR since 2.3; the litert AAR carried both through 2.2).
    // Without the accelerator sibling the GPU request silently falls back to
    // CPU; it costs 3.1 MB per ABI against the encoder speedup it unlocks.
    val sources = mapOf("libLiteRt.so" to "litert", "libLiteRtClGlAccelerator.so" to "litert-gpu")
    val soNames = sources.keys.toList()
    val output = layout.projectDirectory.dir("src/main/jniLibs")
    inputs.property("litertVersion", version)
    outputs.files(
        soNames.flatMap { lib -> listOf(output.file("arm64-v8a/$lib"), output.file("x86_64/$lib")) },
    )
    doLast {
        sources.forEach { (lib, artifact) ->
            val aar = temporaryDir.resolve("$artifact-$version.aar")
            if (!aar.isFile) {
                URI("https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/$artifact/$version/$artifact-$version.aar")
                    .toURL().openStream().use { input -> aar.outputStream().use(input::copyTo) }
            }
            ZipFile(aar).use { zip ->
                listOf("arm64-v8a", "x86_64").forEach { abi ->
                    val entry = zip.getEntry("jni/$abi/$lib")
                        ?: error("LiteRT $version ($artifact) has no $abi $lib")
                    val destination = output.file("$abi/$lib").asFile
                    destination.parentFile.mkdirs()
                    zip.getInputStream(entry).use { input -> destination.outputStream().use(input::copyTo) }
                }
            }
        }
    }
}

// The AAR redistributes LiteRT, so it carries this repo's third-party notices
// too: META-INF/ai.desertant.core/THIRD_PARTY_NOTICES.md in its classes jar, a
// path no other library's META-INF can collide with when an app merges them.
// A generated resource directory through the variant API: AGP 9 refuses a
// Provider in the source set DSL.
abstract class PrepareNotices : DefaultTask() {
    @get:InputFile abstract val notices: RegularFileProperty

    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val dir = outputDir.get().dir("META-INF/ai.desertant.core").asFile
        dir.mkdirs()
        notices.get().asFile.copyTo(dir.resolve("THIRD_PARTY_NOTICES.md"), overwrite = true)
    }
}
// One task per variant: AGP points the task's outputDir at that variant's
// generated directory, so a task shared by two variants would serve both from
// whichever was configured last.
androidComponents.onVariants { variant ->
    val prepareNotices = tasks.register<PrepareNotices>("prepare${variant.name.replaceFirstChar { it.uppercase() }}Notices") {
        notices.set(rootProject.layout.projectDirectory.file("THIRD_PARTY_NOTICES.md"))
    }
    variant.sources.resources?.addGeneratedSourceDirectory(prepareNotices, PrepareNotices::outputDir)
}

tasks.named("preBuild").configure { dependsOn(prepareLiteRt) }

dependencies {
    // HostBridge.kt parses the Hugging Face tree JSON and emits the binary value
    // tree with kotlinx.serialization; the model SDKs already pull the same lib.
    implementation(libs.kotlinx.serialization.json)
    // LoadedModel uses Dispatchers internally for download and inference.
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
}

desertAntPublish {
    displayName = "Desert Ant Core"
    description =
        "Reusable Android host bridge for Desert Ant Labs on-device model SDKs: the JVM " +
            "counterpart to desert-ant-core's Swift JNI harness (host regex, JSON, NFKC, HTTP, " +
            "and license persistence)."
}

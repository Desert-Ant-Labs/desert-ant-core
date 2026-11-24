// Pure-Kotlin library for Tongue: ai.desertant:tongue, a plain jar rather than
// an AAR. The pipeline is a direct Kotlin port using only java.text.Normalizer
// and java.util.regex, so the same artifact serves Android (minSdk 24 is the
// repo convention; both APIs predate API 1) and JVM 17+ with no native code and
// no NDK ABIs, which is also why this module takes no dependency on :core (an
// AAR a JVM consumer cannot resolve) and nothing beyond kotlin-stdlib reaches
// the POM. The 2 MB int8 model ships as a jar resource. Everything structural
// lives in the ai.desertant.jvm-model-sdk convention (gradle-plugin/).
plugins { id("ai.desertant.jvm-model-sdk") }

desertAntSdk {
    description = "On-device language identification for short text, across 84 languages. " +
        "Pure Kotlin: no native code and no inference runtime."
}

sourceSets.test {
    kotlin.srcDir(rootProject.file("Tools/android/tongue"))
    resources.srcDir(rootProject.file("Tests/TongueTests/Resources"))
}

// A model load asks for a license. Nothing listens on this port, so no run from here reaches the license server.
val deadLicenseEndpoint = "http://127.0.0.1:9/api/v1"
// The license file of these runs stays in the build directory, out of the developer's home.
val licenseStateDir = layout.buildDirectory.dir("license-state").get().asFile.path

tasks.test {
    environment("DAL_LICENSE_ENDPOINT", deadLicenseEndpoint)
    environment("DAL_STATE_DIR", licenseStateDir)
}

tasks.register<JavaExec>("goldenVectors") {
    description = "Replay golden/ through this port; the cross-platform contract."
    group = "verification"
    environment("DAL_LICENSE_ENDPOINT", deadLicenseEndpoint)
    environment("DAL_STATE_DIR", licenseStateDir)
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("ai.desertant.tongue.GoldenVectorTestKt")
}

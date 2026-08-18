// Pure-Kotlin library for Tongue: ai.desertant:tongue, a plain jar rather than
// an AAR. The pipeline is a direct Kotlin port using only java.text.Normalizer
// and java.util.regex, so the same artifact serves Android (minSdk 24 is the
// repo convention; both APIs predate API 1) and JVM 17+ with no native code and
// no NDK ABIs — which is also why this module takes no dependency on :core (an
// AAR a JVM consumer cannot resolve) and nothing beyond kotlin-stdlib reaches
// the POM. The 2 MB int8 model ships as a jar resource. Everything structural
// lives in the ai.desertant.jvm-model-sdk convention (gradle-plugin/).
plugins { id("ai.desertant.jvm-model-sdk") }

desertAntSdk {
    description = "On-device language identification for short text, across 84 languages. " +
        "Pure Kotlin: no native code and no inference runtime."
}

// src/test/resources is already a test resource root by convention; re-adding it
// makes processTestResources see every vector file twice and fail on duplicates.

tasks.register<JavaExec>("goldenVectors") {
    description = "Replay golden/ through this port; the cross-platform contract."
    group = "verification"
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("ai.desertant.tongue.GoldenVectorTestKt")
}
tasks.named("check") { dependsOn("goldenVectors") }

// Android library (AAR) for Schemer: ai.desertant:schemer. Everything structural -
// AGP, Kotlin, publishing, the ai.desertant:core dependency, and the Swift JNI
// cross-compile - lives in the shared ai.desertant.model-sdk convention plugin
// (gradle-plugin/). The version comes from VERSION at the repo root, so the only
// thing left here is what is genuinely Schemer's.
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device structured extraction for Android: free text plus a schema you define, " +
        "and typed JSON back, fully on device and in 13 languages."
}

android {
    // The goldens and wire bytes the Swift and Node suites use, so every SDK is
    // held to the same answers and the same payload format.
    sourceSets.getByName("androidTest").assets.srcDirs(rootDir.resolve("Tests/SchemerTests/Resources"))
}

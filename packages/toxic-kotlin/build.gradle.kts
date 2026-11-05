// Android library (AAR) for Toxic: ai.desertant:toxic. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device hate-speech triage for Android: scores a text for hate, abuse and threats, and " +
        "says which group a hateful text targets, fully on device."
}

android {
    // The goldens the Swift and Node suites use, so every SDK is held to the same
    // numbers. TOXIC_MODEL_DIR adds a local model export (the Hub revision's
    // layout) for runs before that revision is published.
    sourceSets.getByName("androidTest").assets.srcDirs(
        listOfNotNull(rootDir.resolve("Tests/ToxicTests/Resources"), System.getenv("TOXIC_MODEL_DIR")))
}

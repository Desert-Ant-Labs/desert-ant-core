// Android library (AAR) for Eye: ai.desertant:eye. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device photo understanding for Android: scenes, quality, faces, people, pets, " +
        "crops and sharpness from one model, fully on device."
}

android {
    // The goldens and fixture the Swift and Node suites use, so every SDK is held
    // to the same numbers. EYE_MODEL_DIR adds a local model export (the Hub
    // revision's layout) for runs before that revision is published.
    sourceSets.getByName("androidTest").assets.srcDirs(
        listOfNotNull(rootDir.resolve("Tests/EyeTests/Resources"), System.getenv("EYE_MODEL_DIR")))
}

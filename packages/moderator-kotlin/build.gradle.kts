// Android library (AAR) for Moderator: ai.desertant:moderator. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device NSFW image detection for Android: scores an image for nudity or sexual " +
        "activity, tuned to pass swimwear and lingerie, fully on device."
}

android {
    // The goldens and SFW fixture the Swift and Node suites use, so every SDK is
    // held to the same numbers. MODERATOR_MODEL_DIR adds a local model export
    // (the Hub revision's layout) for runs before that revision is published.
    sourceSets.getByName("androidTest").assets.srcDirs(
        listOfNotNull(rootDir.resolve("Tests/ModeratorTests/Resources"), System.getenv("MODERATOR_MODEL_DIR")))
}

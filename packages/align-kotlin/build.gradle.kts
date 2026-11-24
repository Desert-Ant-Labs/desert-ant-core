// Android library (AAR) for Align: ai.desertant:align. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device word-timestamp refinement for Android: correct the " +
        "start and end of every word in a transcript against its audio."
}

android {
    sourceSets.getByName("androidTest").assets.srcDir(rootDir.resolve("Tests/AlignTests/Resources"))
}

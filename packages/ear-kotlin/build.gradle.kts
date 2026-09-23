// Android library (AAR) for Ear: ai.desertant:ear. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device spoken language identification for Android: name the " +
        "language of a recording before you transcribe it."
}

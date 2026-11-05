// Android library (AAR) for Uhm: ai.desertant:uhm. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device filler-word detection for Android: find every \"uh\", " +
        "\"um\", and \"hmm\" in a recording."
}

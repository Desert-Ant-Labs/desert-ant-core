// Android library (AAR) for Voz: ai.desertant:voz. Everything structural - AGP,
// Kotlin, publishing, the ai.desertant:core dependency, and the Swift JNI
// cross-compile - lives in the shared ai.desertant.model-sdk convention plugin
// (gradle-plugin/). The version comes from VERSION at the repo root, so the only
// thing left here is what is genuinely Voz's.
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device speech recognition for Android: transcripts with " +
        "word-level timestamps, 25 languages."
}

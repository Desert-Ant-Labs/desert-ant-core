// Android library (AAR) for Gist: ai.desertant:gist. Everything structural - AGP,
// Kotlin, publishing, the ai.desertant:core dependency, and the Swift JNI
// cross-compile - lives in the shared ai.desertant.model-sdk convention plugin
// (gradle-plugin/). The version comes from VERSION at the repo root, so the only
// thing left here is what is genuinely Gist's.
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device content topic tagging for Android: multi-label topics from a fixed " +
        "36-topic taxonomy across 101 languages, fully on device."
}

// Android library (AAR) for Who: ai.desertant:who. Everything structural - AGP,
// Kotlin, publishing, the ai.desertant:core dependency, and the Swift JNI
// cross-compile - lives in the shared ai.desertant.model-sdk convention plugin
// (gradle-plugin/). The version comes from VERSION at the repo root, so the only
// thing left here is what is genuinely Who's.
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device speaker labeling for Android: per-person turns " +
        "with timestamps."
}

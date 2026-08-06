// Android library (AAR) for Emo: ai.desertant:emo. Everything structural - AGP,
// Kotlin, publishing, the ai.desertant:core dependency, and the Swift JNI
// cross-compile - lives in the shared ai.desertant.model-sdk convention plugin
// (gradle-plugin/). The version comes from VERSION at the repo root, so the only
// thing left here is what is genuinely Emo's.
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device multilingual emoji suggestion for Android: turns a short task, calendar " +
        "entry, or message into ranked emoji, fully on device."
}

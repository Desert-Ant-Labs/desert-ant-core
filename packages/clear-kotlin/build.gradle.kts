// Android library (AAR) for Clear: ai.desertant:clear. Everything structural -
// AGP, Kotlin, publishing, the ai.desertant:core dependency, and the Swift JNI
// cross-compile - lives in the shared ai.desertant.model-sdk convention plugin
// (gradle-plugin/). The version comes from VERSION at the repo root, so the only
// thing left here is what is genuinely Clear's.
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device speech enhancement for Android: denoise, dereverb, and " +
        "loudness-normalize a noisy recording to a podcast-ready 48 kHz mono file."
}

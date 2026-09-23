// Android library (AAR) for Clear: ai.desertant:clear. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device speech enhancement for Android: denoise, dereverb, and " +
        "loudness-normalize a noisy recording to a podcast-ready 48 kHz mono file."
}

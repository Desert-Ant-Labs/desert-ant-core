// Android library (AAR) for Shapes: ai.desertant:shapes. Everything structural -
// AGP, Kotlin, publishing, the ai.desertant:core dependency, and the Swift JNI
// cross-compile - lives in the shared ai.desertant.model-sdk convention plugin
// (gradle-plugin/). The version comes from VERSION at the repo root, so the only
// thing left here is what is genuinely Shapes'.
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device single-stroke shape recognition for Android: turns one hand-drawn stroke " +
        "into a clean line, rectangle, triangle, ellipse, or star, fully on device."
}

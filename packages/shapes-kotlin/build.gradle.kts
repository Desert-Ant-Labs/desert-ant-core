// Android library (AAR) for Shapes: ai.desertant:shapes. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device single-stroke shape recognition for Android: turns one hand-drawn stroke " +
        "into a clean line, rectangle, triangle, ellipse, or star, fully on device."
}

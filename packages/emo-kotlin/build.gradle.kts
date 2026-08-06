// Android library (AAR) for Emo. The AGP/Kotlin/publish boilerplate and the Swift
// native build wiring live in the shared ai.desertant.model-sdk convention plugin
// (published from desert-ant-core); this file supplies only Emo's version and
// description. `mise run build-android` -> `mise run android-natives` builds the
// prebuilt Swift JNI into src/main/jniLibs before packaging.
plugins { id("ai.desertant.model-sdk") version "1.0.1" }
version = "1.0.1"
desertAntSdk {
    // Pinned exactly, like the npm package: one version across the repo.
    coreVersion = "1.0.1"
    description = "On-device multilingual emoji suggestion for Android: turns a short task, calendar " +
        "entry, or message into ranked emoji, fully on device."
}

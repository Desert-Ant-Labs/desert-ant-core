plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device face matching for Android: find the faces in a photo, group a library into people, " +
        "and tell who is who, fully on device."
}

android {
    sourceSets.getByName("androidTest").assets.srcDirs(
        listOfNotNull(rootDir.resolve("Tests/FaceTests/Resources"), System.getenv("FACE_MODEL_DIR")))
}

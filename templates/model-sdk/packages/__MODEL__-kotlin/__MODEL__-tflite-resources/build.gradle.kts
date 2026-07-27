// Optional bundled model for __PRODUCT__ on Android; the ai.desertant.model-resources
// convention plugin packages the LiteRT files staged by `mise run android-natives`.
plugins { id("ai.desertant.model-resources") }
version = "0.1.0"
desertAntResources { tfliteFiles = listOf("__MODEL__.tflite", "__MODEL___meta.json") }

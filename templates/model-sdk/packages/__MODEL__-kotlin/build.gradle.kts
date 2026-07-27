// Android library (AAR) for __PRODUCT__. The AGP/Kotlin/publish boilerplate and the
// Swift native build wiring live in the shared ai.desertant.model-sdk convention
// plugin (published from desert-ant-core); this file supplies only the version
// and description.
plugins { id("ai.desertant.model-sdk") version "__PLUGIN_VERSION__" }
version = "0.1.0"
desertAntSdk {
    description = "__DESCRIPTION__"
}

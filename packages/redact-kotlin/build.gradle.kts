// Android library (AAR) for Redact. The AGP/Kotlin/publish boilerplate and the
// Swift native build wiring live in the shared ai.desertant.model-sdk convention
// plugin (published from desert-ant-core); this file supplies only Redact's
// version and description. `mise run build-android` -> `mise run android-natives`
// builds the prebuilt Swift JNI into src/main/jniLibs before packaging.
plugins { id("ai.desertant.model-sdk") version "0.4.2" }
version = "0.7.3"
desertAntSdk {
    description = "On-device multilingual PII redaction for Android: names, addresses, emails, cards, " +
        "IBANs, national IDs, VAT numbers and more across 24 EU languages."
}

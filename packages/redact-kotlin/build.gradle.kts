// Android library (AAR) for Redact: ai.desertant:redact. Everything structural -
// AGP, Kotlin, publishing, the ai.desertant:core dependency, and the Swift JNI
// cross-compile - lives in the shared ai.desertant.model-sdk convention plugin
// (gradle-plugin/). The version comes from VERSION at the repo root, so the only
// thing left here is what is genuinely Redact's.
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device multilingual PII redaction for Android: names, addresses, emails, cards, " +
        "IBANs, national IDs and VAT numbers, across 27 languages."
}

// Android library (AAR) for Redact: ai.desertant:redact. Everything structural comes
// from the ai.desertant.model-sdk convention plugin (gradle-plugin/).
plugins { id("ai.desertant.model-sdk") }

desertAntSdk {
    description = "On-device multilingual PII redaction for Android: names, addresses, emails, cards, " +
        "IBANs, national IDs and VAT numbers, across 27 languages."
}
